defmodule PlausibleWeb.TrafficControllerTest do
  use PlausibleWeb.ConnCase, async: false

  setup [:create_user, :log_in]

  setup %{user: user} do
    site = insert(:site, domain: "traffic.example", members: [user])
    %{site: site}
  end

  test "shows classes, reasons and the Cloudflare hint", %{conn: conn, site: site} do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    populate_stats(site, [
      build(:pageview, user_id: 1, timestamp: now),
      build(:pageview, user_id: 2, timestamp: now, traffic: 1)
      |> Map.put(:traffic_reasons, ["forged_search_referrer"])
    ])

    html = conn |> get("/traffic.example/traffic") |> html_response(200)

    assert html =~ "Traffic quality"
    assert html =~ "forged_search_referrer"
    assert html =~ "Suspicious alone"
    assert html =~ "CLOUDFLARE_API_TOKEN"
  end

  test "shows stored edge requests", %{conn: conn, site: site} do
    today = Date.utc_today()

    Plausible.Repo.insert_all(Plausible.EdgeRequests.Row, [
      %{
        site_id: site.id,
        date: today,
        agent: "GPTBot",
        category: "ai_training",
        requests: 1234,
        inserted_at: DateTime.utc_now()
      },
      %{
        site_id: site.id,
        date: today,
        agent: "Browsers",
        category: "browser",
        requests: 40,
        inserted_at: DateTime.utc_now()
      }
    ])

    html = conn |> get("/traffic.example/traffic?days=28") |> html_response(200)
    assert html =~ "GPTBot"
    assert html =~ "1,234"
    assert html =~ "AI training"
  end

  test "is not available to viewers", %{conn: conn, user: user} do
    site = insert(:site, domain: "viewer.example")
    insert(:site_membership, site: site, user: user, role: :viewer)
    conn = get(conn, "/viewer.example/traffic")
    assert conn.status in [302, 404]
  end

  test "writes a summary on request", %{conn: conn} do
    Application.put_env(:plausible, Plausible.TrafficReport,
      api_key: "k",
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn -> Application.delete_env(:plausible, Plausible.TrafficReport) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => "Summary\n- All quiet."}]
      })
    end)

    html =
      conn
      |> post("/traffic.example/traffic/report", %{"days" => "28", "language" => "en"})
      |> html_response(200)

    assert html =~ "Written summary"
    assert html =~ "All quiet."
  end
end
