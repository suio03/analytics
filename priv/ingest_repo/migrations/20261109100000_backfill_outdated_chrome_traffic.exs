defmodule Plausible.IngestRepo.Migrations.BackfillOutdatedChromeTraffic do
  @moduledoc """
  Marks recent direct visits from outdated desktop Chrome as suspicious.

  In early November 2026 scraper fleets from China, Singapore and Hong Kong
  sent single-page, zero-duration direct visits with desktop Chrome 148-150
  while real visitors were on 156/157. `Plausible.Ingestion.Traffic` now flags
  them (`outdated_browser` + `no_referrer`); this applies the same rule to the
  sessions stored before. The current Chrome major is estimated per session
  date with the same release cadence as the live classifier.
  """

  use Ecto.Migration

  @since ~N[2026-10-01 00:00:00]

  # Keep in sync with Plausible.Ingestion.Traffic: Chrome 131 on 2024-11-12,
  # a release every 28 days, outdated when 6 or more releases behind.
  @sessions_condition """
  start >= {since:DateTime}
  AND traffic = 0
  AND pageviews > 0
  AND browser = 'Chrome'
  AND screen_size = 'Desktop'
  AND referrer_source = ''
  AND utm_source = ''
  AND toUInt32OrZero(splitByChar('.', browser_version)[1]) > 0
  AND toUInt32OrZero(splitByChar('.', browser_version)[1]) <=
      131 + intDiv(dateDiff('day', toDate('2024-11-12'), toDate(start)), 28) - 6
  """

  def up do
    # The events mutation reads sessions_v2, so it has to run first and
    # synchronously, before the sessions themselves are updated.
    query!(
      """
      ALTER TABLE events_v2
      #{Plausible.MigrationUtils.on_cluster_statement("events_v2")}
      UPDATE traffic = 1
      WHERE timestamp >= {since:DateTime}
        AND traffic = 0
        AND session_id IN (SELECT session_id FROM sessions_v2 WHERE #{@sessions_condition})
      """,
      allow_nondeterministic_mutations: 1,
      mutations_sync: 2
    )

    query!(
      """
      ALTER TABLE sessions_v2
      #{Plausible.MigrationUtils.on_cluster_statement("sessions_v2")}
      UPDATE traffic = 1,
        traffic_reasons = arrayConcat(traffic_reasons, ['outdated_browser', 'no_referrer'])
      WHERE #{@sessions_condition}
      """,
      mutations_sync: 2
    )
  end

  def down, do: :ok

  defp query!(sql, settings) do
    repo().query!(sql, %{"since" => @since}, settings: settings)
  end
end
