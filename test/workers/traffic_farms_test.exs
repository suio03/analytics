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

  # ClickHouse isn't rolled back between tests, so only look at this test's site
  defp farms(site) do
    TrafficFarms.run(@now) |> Enum.filter(fn [site_id | _] -> site_id == site.id end)
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
end
