defmodule PlausibleWeb.EconomicsControllerTest do
  use PlausibleWeb.ConnCase, async: false
  alias Plausible.Economics

  setup [:create_user, :log_in]

  setup %{user: user} do
    site = insert(:site, domain: "economics.example", members: [user])
    Application.put_env(:plausible, Plausible.Economics, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:plausible, Plausible.Economics) end)
    %{site: site}
  end

  @report %{
    "generatedAt" => "2026-11-09T10:00:00Z",
    "days" => 56,
    "cohortDays" => 30,
    "notes" => ["Free cost: model calls."],
    "daily" => [
      %{
        "day" => "2026-11-08",
        "signups" => 108,
        "freeUsd" => 18.12,
        "paidUsd" => 25.64,
        "orders" => 6,
        "firstOrders" => 2,
        "revenue" => 136
      }
    ],
    "weeks" => [
      %{
        "key" => "2026-10-05",
        "signups" => 40,
        "buyers" => 2,
        "freeUsd" => 10.0,
        "revenue" => 50.0,
        "payback" => 5.0,
        "age" => 30,
        "freePerSignup" => 0.25
      }
    ],
    "sources" => [
      %{
        "key" => "(before tracking)",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "(direct or unknown)",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "email",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "google",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "search.brave.com",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "newref",
        "signups" => 3,
        "buyers" => 0,
        "freeUsd" => 0,
        "revenue" => 0,
        "payback" => nil,
        "freePerSignup" => 0
      },
      %{
        "key" => "sunodownloader",
        "signups" => 55,
        "buyers" => 0,
        "freeUsd" => 18.27,
        "revenue" => 0,
        "payback" => 0.0,
        "freePerSignup" => 0.332
      }
    ]
  }

  test "empty state links to the endpoint form", %{conn: conn} do
    assert get(conn, "/economics.example/economics") |> html_response(200) =~
             "Connect a cost report"

    assert get(conn, "/economics.example/economics/settings") |> html_response(200) =~
             "Bearer token"
  end

  test "renders the report and sends the token, never shows it", %{conn: conn, site: site} do
    {:ok, _} =
      Economics.save_source(site.id, %{
        "url" => "https://app.example/api/ops/economics",
        "token" => "never-render-this-token"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer never-render-this-token"]
      assert conn.query_string == "days=90"
      Req.Test.json(conn, @report)
    end)

    html = get(conn, "/economics.example/economics?days=90") |> html_response(200)
    assert html =~ "sunodownloader"
    assert html =~ "/favicon/sources/sunodownloader.io"
    assert html =~ "/favicon/sources/search.brave.com"
    assert html =~ "Before source tracking"
    assert html =~ "newref"
    assert html =~ "$18.27"
    assert html =~ "5.0×"
    refute html =~ "never-render-this-token"

    settings = get(conn, "/economics.example/economics/settings") |> html_response(200)
    refute settings =~ "never-render-this-token"
  end

  test "a refused token shows an error", %{conn: conn, site: site} do
    {:ok, _} = Economics.save_source(site.id, %{"url" => "https://app.example/x", "token" => "t"})
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "Forbidden") end)
    assert get(conn, "/economics.example/economics") |> html_response(200) =~ "refused the token"
  end

  test "saving requires https and keeps the token when blank", %{conn: conn, site: site} do
    conn1 =
      post(conn, "/economics.example/economics/settings", %{
        "source" => %{"url" => "http://app.example/x", "token" => "t"}
      })

    assert html_response(conn1, 422) =~ "https://"

    post(conn, "/economics.example/economics/settings", %{
      "source" => %{"url" => "https://app.example/x", "token" => "first"}
    })

    post(conn, "/economics.example/economics/settings", %{
      "source" => %{"url" => "https://app.example/y", "token" => ""}
    })

    conn2 =
      post(conn, "/economics.example/economics/settings", %{"source" => %{"url" => "   "}})

    assert html_response(conn2, 422) =~ "blank"

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "days=56"
      Req.Test.json(conn, @report)
    end)

    assert get(conn, "/economics.example/economics?days[]=1") |> html_response(200)

    source = Economics.source(site.id)
    assert source.url == "https://app.example/y"
    assert source.token == "first"
  end

  test "nonmembers cannot open it", %{conn: conn} do
    other = insert(:site, domain: "other-economics.example", public: true)
    assert get(conn, "/#{other.domain}/economics") |> html_response(404)
    assert get(conn, "/#{other.domain}/economics/settings") |> html_response(404)
  end
end
