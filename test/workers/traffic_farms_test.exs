defmodule Plausible.Workers.TrafficFarmsTest do
  use Plausible.DataCase
  import Ecto.Query

  alias Plausible.Workers.TrafficFarms

  @now ~N[2026-11-12 12:00:00]
  @farm 111
  @other 222

  setup do
    {:ok, site: insert(:site)}
  end

  defp pageview(site, network, attrs \\ []) do
    :pageview
    |> build(Keyword.merge([site_id: site.id, timestamp: ~N[2026-11-12 08:00:00]], attrs))
    |> Map.put(:network, network)
  end

  # One client signature, as a proxy-rotating crawler sends it
  @crawler [
    browser: "Chrome",
    browser_version: "157.0",
    operating_system: "GNU/Linux",
    operating_system_version: "",
    screen_size: "Desktop",
    country_code: "US",
    referrer_source: "Google"
  ]

  # ClickHouse isn't rolled back between tests, so only look at this test's site
  defp farms(site, reason \\ "oneshot_farm") do
    TrafficFarms.run(@now)
    |> Map.fetch!(reason)
    |> Enum.filter(fn [site_id | _] -> site_id == site.id end)
  end

  defp sessions(site) do
    Plausible.ClickhouseRepo.all(
      from s in Plausible.ClickhouseSessionV2,
        hints: unsafe_fragment(^"FINAL"),
        where: s.site_id == ^site.id,
        select: {s.network, s.traffic, s.traffic_reasons}
    )
  end

  defp events_by_traffic(site) do
    Plausible.ClickhouseRepo.all(
      from e in Plausible.ClickhouseEventV2,
        where: e.site_id == ^site.id,
        group_by: e.traffic,
        select: {e.traffic, count()}
    )
    |> Map.new()
  end

  test "marks the one-shot sessions of a farm network as suspicious", %{site: site} do
    farm = for _ <- 1..30, do: pageview(site, @farm)
    others = for _ <- 1..30, do: pageview(site, @other)

    # A returning visitor from the farm network keeps its class
    user_id = 42

    returning = [
      pageview(site, @farm, user_id: user_id),
      pageview(site, @farm, user_id: user_id, timestamp: ~N[2026-11-12 08:01:00])
    ]

    populate_stats(farm ++ returning)
    # Another network with too few visitors is left alone even if all are one-shot
    populate_stats(Enum.take(others, 29))

    assert [[_site_id, ~D[2026-11-12], @farm]] = farms(site)

    sessions = sessions(site)
    assert Enum.count(sessions, &match?({@farm, 1, ["oneshot_farm"]}, &1)) == 30
    assert Enum.count(sessions, &match?({@farm, 0, []}, &1)) == 1
    assert Enum.count(sessions, &match?({@other, 0, []}, &1)) == 29

    assert %{1 => 30, 0 => 31} = events_by_traffic(site)

    # Repeating finds the network again but changes nothing
    TrafficFarms.run(@now)
    assert %{1 => 30, 0 => 31} = events_by_traffic(site)
  end

  test "a network whose visitors mostly engage is not a farm", %{site: site} do
    oneshot = for _ <- 1..30, do: pageview(site, @farm)

    engaged =
      for i <- 1..10 do
        [
          pageview(site, @farm, user_id: i),
          pageview(site, @farm, user_id: i, timestamp: ~N[2026-11-12 08:02:00])
        ]
      end

    populate_stats(oneshot ++ List.flatten(engaged))

    assert [] = farms(site)
  end

  test "sessions that may still be active are not judged", %{site: site} do
    populate_stats(for _ <- 1..30, do: pageview(site, @farm, timestamp: ~N[2026-11-12 11:45:00]))

    assert [] = farms(site)
  end

  test "sessions without a network are ignored", %{site: site} do
    populate_stats(for _ <- 1..30, do: pageview(site, 0))

    assert [] = farms(site)
  end

  test "marks one-shot visitors sharing a client signature across networks", %{site: site} do
    crawler = for n <- 1..30, do: pageview(site, n, @crawler)
    # Same browser from elsewhere, and a visitor of the signature who came back
    others = for n <- 1..10, do: pageview(site, n, Keyword.put(@crawler, :country_code, "DE"))

    returning = [
      pageview(site, 99, Keyword.put(@crawler, :user_id, 7)),
      pageview(
        site,
        99,
        @crawler |> Keyword.put(:user_id, 7) |> Keyword.put(:timestamp, ~N[2026-11-12 08:03:00])
      )
    ]

    populate_stats(crawler ++ others ++ returning)

    assert [] = farms(site)
    assert [[_site_id, ~D[2026-11-12], _key]] = farms(site, "oneshot_cohort")

    sessions = sessions(site)
    assert Enum.count(sessions, &match?({_, 1, ["oneshot_cohort"]}, &1)) == 30
    assert Enum.count(sessions, &match?({_, 0, []}, &1)) == 11
  end

  test "a signature whose visitors mostly engage is not a farm", %{site: site} do
    oneshot = for n <- 1..30, do: pageview(site, n, @crawler)

    engaged =
      for i <- 1..10 do
        attrs = Keyword.put(@crawler, :user_id, 100 + i)

        [
          pageview(site, i, attrs),
          pageview(site, i, Keyword.put(attrs, :timestamp, ~N[2026-11-12 08:02:00]))
        ]
      end

    populate_stats(oneshot ++ List.flatten(engaged))

    assert [] = farms(site, "oneshot_cohort")
  end

  test "a network farm is marked once, as oneshot_farm", %{site: site} do
    populate_stats(for _ <- 1..30, do: pageview(site, @farm, @crawler))

    assert [_] = farms(site)
    assert Enum.all?(sessions(site), &match?({@farm, 1, ["oneshot_farm"]}, &1))
  end
end
