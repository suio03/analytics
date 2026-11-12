defmodule Plausible.TrafficAlertsTest do
  use Plausible.DataCase, async: false

  alias Plausible.TrafficAlerts

  @day ~D[2026-11-11]

  defp at(date, hour \\ 12), do: NaiveDateTime.new!(date, Time.new!(hour, 0, 0))

  defp visits(n, date, attrs \\ []) do
    for _ <- 1..n do
      {reasons, attrs} = Keyword.pop(attrs, :traffic_reasons, [])

      build(
        :pageview,
        Keyword.merge([user_id: System.unique_integer([:positive]), timestamp: at(date)], attrs)
      )
      |> Map.put(:traffic_reasons, reasons)
    end
  end

  test "a quiet day has no alerts" do
    site = insert(:site)

    events =
      for offset <- 0..14, do: visits(30, Date.add(@day, -offset), referrer_source: "Google")

    populate_stats(site, List.flatten(events))
    assert TrafficAlerts.evaluate(site.id, @day) == []
  end

  test "rule alerts for non-human share, forged referrers and farms" do
    site = insert(:site)

    populate_stats(
      site,
      visits(40, @day) ++
        visits(30, @day, traffic: 1, traffic_reasons: ["forged_search_referrer"]) ++
        visits(20, @day, traffic: 1, traffic_reasons: ["oneshot_farm"]) ++
        visits(10, @day, traffic: 2, traffic_reasons: ["bot_ua"])
    )

    alerts = TrafficAlerts.evaluate(site.id, @day)
    kinds = Enum.map(alerts, & &1.kind)

    assert hd(alerts).kind == "nonhuman_share"
    assert hd(alerts).level == :critical
    assert hd(alerts).detail =~ "60% of sessions were suspicious or bots (60 of 100)"
    assert "forged_search" in kinds
    assert "visitor_farm" in kinds
    assert "nonhuman_surge" in kinds
  end

  test "baseline anomalies: a drop in human sessions and a source surge" do
    site = insert(:site)

    baseline = for offset <- 1..14, do: visits(50, Date.add(@day, -offset))

    populate_stats(
      site,
      List.flatten(baseline) ++ visits(10, @day) ++ visits(40, @day, referrer_source: "Reddit")
    )

    alerts = TrafficAlerts.evaluate(site.id, @day)
    assert Enum.any?(alerts, &(&1.kind == "source_surge" and &1.title == "Surge from Reddit"))
    refute Enum.any?(alerts, &(&1.kind == "human_sessions"))

    site2 = insert(:site)

    populate_stats(
      site2,
      List.flatten(for o <- 1..14, do: visits(50, Date.add(@day, -o))) ++ visits(5, @day)
    )

    assert [%{kind: "human_sessions", title: "Human sessions dropped", level: :warning}] =
             TrafficAlerts.evaluate(site2.id, @day)
  end

  test "drop_or_spike ignores small sites" do
    assert TrafficAlerts.drop_or_spike(0, List.duplicate(10, 14), %{kind: "x", title: "X"}) == nil

    assert %{title: "X spiked"} =
             TrafficAlerts.drop_or_spike(300, List.duplicate(100, 14), %{kind: "x", title: "X"})
  end
end
