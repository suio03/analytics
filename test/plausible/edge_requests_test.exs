defmodule Plausible.EdgeRequestsTest do
  use Plausible.DataCase, async: false

  alias Plausible.EdgeRequests

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"

  setup do
    Application.put_env(:plausible, EdgeRequests, token: "t", plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:plausible, EdgeRequests) end)
    :ok
  end

  defp group(count, dims), do: %{"count" => count, "dimensions" => dims}

  defp stub_cloudflare(test_pid) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/client/v4/zones" ->
          Req.Test.json(conn, %{
            "result" => [
              %{"id" => "zone-example", "name" => "example.com"},
              %{"id" => "zone-other", "name" => "other.org"}
            ],
            "result_info" => %{"total_pages" => 1}
          })

        "/client/v4/graphql" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:graphql, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "data" => %{
              "viewer" => %{
                "zones" => [
                  %{
                    "totals" => [
                      group(120, %{"date" => "2026-11-11"}),
                      group(10, %{"date" => "2026-11-12"})
                    ],
                    "agents" => [
                      group(50, %{"date" => "2026-11-11", "userAgent" => @chrome}),
                      group(30, %{
                        "date" => "2026-11-11",
                        "userAgent" =>
                          "Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)"
                      }),
                      group(5, %{
                        "date" => "2026-11-11",
                        "userAgent" =>
                          "Mozilla/5.0 (compatible; GPTBot/1.1; +https://openai.com/gptbot)"
                      }),
                      group(10, %{"date" => "2026-11-12", "userAgent" => "curl/8.4.0"})
                    ]
                  }
                ]
              }
            },
            "errors" => nil
          })
      end
    end)
  end

  test "is off without a token" do
    Application.put_env(:plausible, EdgeRequests, token: nil)
    refute EdgeRequests.enabled?()
    assert EdgeRequests.sync_all() == {:error, :disabled}
  end

  test "matches a site to the longest zone suffix" do
    zones = [%{id: "a", name: "example.com"}, %{id: "b", name: "app.example.com"}]
    assert EdgeRequests.zone_for("example.com", zones) == "a"
    assert EdgeRequests.zone_for("www.example.com", zones) == "a"
    assert EdgeRequests.zone_for("x.app.example.com", zones) == "b"
    assert EdgeRequests.zone_for("notexample.com", zones) == nil
  end

  test "syncs sites in readable zones and counts the unlisted tail as browsers" do
    stub_cloudflare(self())
    site = insert(:site, domain: "example.com")
    _no_zone = insert(:site, domain: "elsewhere.net")

    results = EdgeRequests.sync_all(~D[2026-11-12], 3)
    assert {"example.com", {:ok, 3}} in results
    refute Enum.any?(results, fn {domain, _} -> domain == "elsewhere.net" end)

    assert_received {:graphql, %{"variables" => vars}}

    assert vars == %{
             "zone" => "zone-example",
             "since" => "2026-11-10",
             "until" => "2026-11-12",
             "hosts" => ["example.com", "www.example.com"]
           }

    report = EdgeRequests.report(site.id, 7, ~D[2026-11-12])
    assert report.total == 130
    assert report.categories == %{"browser" => 85, "ai_training" => 35, "other_bot" => 10}

    assert report.agents == [
             %{agent: "GPTBot", category: "ai_training", requests: 35},
             %{agent: "curl", category: "other_bot", requests: 10}
           ]

    assert report.daily[~D[2026-11-11]] == %{"browser" => 85, "ai_training" => 35}

    # Re-syncing replaces the window instead of adding to it.
    EdgeRequests.sync_all(~D[2026-11-12], 3)
    assert EdgeRequests.report(site.id, 7, ~D[2026-11-12]).total == 130
  end

  test "reports Cloudflare errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/client/v4/zones" ->
          Req.Test.json(conn, %{
            "result" => [%{"id" => "z", "name" => "example.com"}],
            "result_info" => %{"total_pages" => 1}
          })

        _ ->
          Req.Test.json(conn, %{"data" => nil, "errors" => [%{"message" => "not authorized"}]})
      end
    end)

    insert(:site, domain: "example.com")
    assert [{"example.com", {:error, "Cloudflare: not authorized"}}] = EdgeRequests.sync_all()
  end
end
