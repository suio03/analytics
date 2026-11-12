defmodule Plausible.Workers.TrafficFarms do
  @moduledoc """
  Marks one-shot visitor farms as suspicious traffic.

  A farm is one network (`sessions_v2.network`, see
  `Plausible.Ingestion.Network`) sending a site many visitors that each view a
  single page, never interact and never come back. Taken one at a time they
  look like ordinary bounces, so the classifier at session start can't see
  them; grouped by network they stand out. No fingerprint and no earlier bot
  verdict is needed.

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

  @doc "Finds farms among sessions started since yesterday and marks them. Returns the farms."
  def run(now \\ NaiveDateTime.utc_now()) do
    now = NaiveDateTime.truncate(now, :second)
    since = now |> NaiveDateTime.to_date() |> Date.add(-1) |> NaiveDateTime.new!(~T[00:00:00])
    settled = NaiveDateTime.add(now, -@settle_minutes * 60)

    case find_farms(since, settled) do
      [] ->
        []

      farms ->
        mark(farms, since, settled)

        Logger.notice(
          "TrafficFarms: marked one-shot sessions of #{length(farms)} network(s) as suspicious"
        )

        farms
    end
  end

  defp find_farms(since, settled) do
    %{rows: rows} =
      Plausible.IngestRepo.query!(
        """
        SELECT site_id, toDate(start) AS day, network
        FROM sessions_v2 FINAL
        WHERE start >= {since:DateTime} AND timestamp < {settled:DateTime} AND network != 0
        GROUP BY site_id, day, network
        HAVING uniqIf(user_id, #{@oneshot}) >= {min_visitors:UInt32}
          AND uniqIf(user_id, #{@oneshot}) >= {min_share:Float64} * uniq(user_id)
        """,
        %{
          "since" => since,
          "settled" => settled,
          "min_visitors" => @min_oneshot_visitors,
          "min_share" => @min_oneshot_share
        }
      )

    rows
  end

  defp mark(farms, since, settled) do
    # Farm keys come straight from ClickHouse as integers and a date.
    keys =
      Enum.map_join(farms, ", ", fn [site_id, day, network] ->
        "(#{Integer.to_string(site_id)}, toDate('#{Date.to_iso8601(day)}'), #{Integer.to_string(network)})"
      end)

    sessions = """
    start >= {since:DateTime}
    AND timestamp < {settled:DateTime}
    AND traffic = 0
    AND #{@oneshot}
    AND (site_id, toDate(start), network) IN (#{keys})
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
        AND session_id IN (SELECT session_id FROM sessions_v2 WHERE #{sessions})
      """,
      params,
      settings: [allow_nondeterministic_mutations: 1, mutations_sync: 2]
    )

    Plausible.IngestRepo.query!(
      """
      ALTER TABLE sessions_v2
      #{Plausible.MigrationUtils.on_cluster_statement("sessions_v2")}
      UPDATE traffic = 1, traffic_reasons = arrayConcat(traffic_reasons, ['oneshot_farm'])
      WHERE #{sessions}
      """,
      params,
      settings: [mutations_sync: 2]
    )
  end
end
