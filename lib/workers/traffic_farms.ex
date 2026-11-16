defmodule Plausible.Workers.TrafficFarms do
  @moduledoc """
  Marks one-shot visitor farms as suspicious traffic.

  A farm is a group of visitors that each view a single page and never come
  back. Taken one at a time they look like ordinary bounces, so
  the classifier at session start can't see them; grouped they stand out. No
  earlier bot verdict is needed. Two groupings are checked:

  - `oneshot_farm`: one network (`sessions_v2.network`, see
    `Plausible.Ingestion.Network`).
  - `oneshot_cohort`: one client signature (browser and version, OS and
    version, screen size, country and referrer source), whatever the network.
    This catches crawlers that rotate through proxy addresses, a few per /24,
    with one browser build and one forged referrer (2026-11-16: 82 "Google"
    visitors on Chrome 157 / Linux from one US proxy provider). Over the 28
    days before, no human signature with 30+ visitors on a day had a bounce
    rate above 63% on any site; the crawlers bounced 100%. It needs 95% one-shot
    visitors and ignores sessions already classed as bots. Sessions with no
    identified browser are left to the classifier.

  Runs hourly over yesterday and today (UTC). Networks are compared within one
  UTC day because the network hash uses the daily salt. Only sessions that
  ended at least 30 minutes ago are touched, so the live session cache
  doesn't write a stale class back. The one-shot sessions of a farm network
  become suspicious (`oneshot_farm`); other sessions from the same network
  are left alone. Already classified sessions are not changed, which makes
  the job safe to repeat.
  """

  use Oban.Worker, queue: :traffic_farms, max_attempts: 1

  require Logger

  # A network needs at least this many one-shot visitors on one day ...
  @min_oneshot_visitors 30
  # ... and they must make up at least this share of its visitors.
  @min_oneshot_share 0.9
  @settle_minutes 30

  @oneshot "pageviews <= 1 AND events <= 1 AND interacted = 0"

  # {reason, group key, sessions it applies to, one-shot share}. Keys are
  # UInt64 so they can be written back into the mutation as plain integers. A
  # signature is wider than a network, so it needs a higher share and doesn't
  # count sessions already known to be bots.
  @groupings [
    {"oneshot_farm", "network", "network != 0", @min_oneshot_share},
    {"oneshot_cohort",
     "cityHash64(browser, browser_version, operating_system, operating_system_version, screen_size, country_code, referrer_source)",
     "browser != '' AND traffic != 2", 0.95}
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now =
      case args do
        %{"now" => now} -> NaiveDateTime.from_iso8601!(now)
        _ -> NaiveDateTime.utc_now()
      end

    run(now)
    :ok
  end

  @doc """
  Finds farms among sessions started since yesterday and marks them. Returns
  the farms as `[site_id, day, key]` per reason, e.g. `%{"oneshot_farm" => [...]}`.
  """
  def run(now \\ NaiveDateTime.utc_now()) do
    now = NaiveDateTime.truncate(now, :second)
    since = now |> NaiveDateTime.to_date() |> Date.add(-1) |> NaiveDateTime.new!(~T[00:00:00])
    settled = NaiveDateTime.add(now, -@settle_minutes * 60)

    Map.new(@groupings, fn {reason, key, scope, share} = grouping ->
      case find_farms(key, scope, share, since, settled) do
        [] ->
          {reason, []}

        farms ->
          mark(grouping, farms, since, settled)

          Logger.notice(
            "TrafficFarms: marked one-shot sessions of #{length(farms)} group(s) as suspicious (#{reason})"
          )

          {reason, farms}
      end
    end)
  end

  defp find_farms(key, scope, share, since, settled) do
    %{rows: rows} =
      Plausible.IngestRepo.query!(
        """
        SELECT site_id, toDate(start) AS day, #{key} AS farm_key
        FROM sessions_v2 FINAL
        WHERE start >= {since:DateTime} AND timestamp < {settled:DateTime} AND #{scope}
        GROUP BY site_id, day, farm_key
        HAVING uniqIf(user_id, #{@oneshot}) >= {min_visitors:UInt32}
          AND uniqIf(user_id, #{@oneshot}) >= {min_share:Float64} * uniq(user_id)
        """,
        %{
          "since" => since,
          "settled" => settled,
          "min_visitors" => @min_oneshot_visitors,
          "min_share" => share
        }
      )

    rows
  end

  defp mark({reason, key, scope, _share}, farms, since, settled) do
    # Farm keys come straight from ClickHouse as integers and a date.
    keys =
      Enum.map_join(farms, ", ", fn [site_id, day, farm_key] ->
        "(#{Integer.to_string(site_id)}, toDate('#{Date.to_iso8601(day)}'), #{Integer.to_string(farm_key)})"
      end)

    sessions = """
    start >= {since:DateTime}
    AND timestamp < {settled:DateTime}
    AND traffic = 0
    AND #{@oneshot}
    AND #{scope}
    AND (site_id, toDate(start), #{key}) IN (#{keys})
    """

    params = %{"since" => since, "settled" => settled}

    # The events mutation reads sessions_v2, so it runs first and synchronously.
    Plausible.IngestRepo.query!(
      """
      ALTER TABLE events_v2
      #{Plausible.MigrationUtils.on_cluster_statement("events_v2")}
      UPDATE traffic = 1
      WHERE timestamp >= {since:DateTime}
        AND traffic = 0
        AND session_id IN (SELECT session_id FROM sessions_v2 FINAL WHERE #{sessions})
      """,
      params,
      settings: [allow_nondeterministic_mutations: 1, mutations_sync: 2]
    )

    Plausible.IngestRepo.query!(
      """
      ALTER TABLE sessions_v2
      #{Plausible.MigrationUtils.on_cluster_statement("sessions_v2")}
      UPDATE traffic = 1, traffic_reasons = arrayConcat(traffic_reasons, ['#{reason}'])
      WHERE #{sessions}
      """,
      params,
      settings: [mutations_sync: 2]
    )
  end
end
