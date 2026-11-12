defmodule Plausible.TrafficReportTest do
  use Plausible.DataCase, async: false

  alias Plausible.TrafficReport

  setup do
    on_exit(fn -> Application.delete_env(:plausible, TrafficReport) end)
    %{site: insert(:site, domain: "report.example")}
  end

  test "is off without an API key", %{site: site} do
    Application.delete_env(:plausible, TrafficReport)
    refute TrafficReport.enabled?()
    assert {:error, "Set ANTHROPIC_API_KEY" <> _} = TrafficReport.generate(site, 7)
  end

  test "sends the facts and flags numbers that aren't in them", %{site: site} do
    Application.put_env(:plausible, TrafficReport, api_key: "k", plug: {Req.Test, __MODULE__})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    populate_stats(site, [
      build(:pageview, user_id: 1, timestamp: now),
      build(:pageview, user_id: 2, timestamp: now),
      build(:pageview, user_id: 3, timestamp: now, traffic: 2)
    ])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "claude-sonnet-5-5"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
      assert request["system"] =~ "Write in Simplified Chinese"

      facts = request["messages"] |> hd() |> Map.fetch!("content") |> Jason.decode!()
      assert facts["shares"]["all_sessions"] == 3
      assert facts["shares"]["bot_sessions_pct"] == 33.3

      Req.Test.json(conn, %{
        "stop_reason" => "end_turn",
        "content" => [
          %{"type" => "thinking", "thinking" => ""},
          %{
            "type" => "text",
            "text" => "Summary\n- 33.3% of 3 sessions were bots, about 4,812 a day."
          }
        ]
      })
    end)

    assert {:ok, report} = TrafficReport.generate(site, 7, language: "Simplified Chinese")
    assert report.text =~ "33.3%"
    assert report.ungrounded == ["4812"]
  end

  test "reports refusals and HTTP errors", %{site: site} do
    Application.put_env(:plausible, TrafficReport, api_key: "k", plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"stop_reason" => "refusal", "content" => []})
    end)

    assert {:error, "The model declined" <> _} = TrafficReport.generate(site, 7)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "{}") end)
    assert {:error, "The Claude API answered HTTP 400."} = TrafficReport.generate(site, 7)
  end
end
