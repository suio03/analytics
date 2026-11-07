defmodule Plausible.IngestRepo.Migrations.BackfillUnidentifiedTraffic do
  @moduledoc """
  Marks recent sessions without any browser, operating system or device as
  suspicious traffic.

  Before traffic classification existed, headless browsers with unknown user
  agents (e.g. Lightpanda from AWS, early November 2026) were stored as regular
  visits with `(not set)` browser, OS and device. Their user agents and IPs are
  not stored, so they can only be recognised by those empty columns. They get
  the same reasons the live classifier would give them.
  """

  use Ecto.Migration

  @since ~N[2026-10-01 00:00:00]

  @sessions_condition """
  start >= {since:DateTime}
  AND browser = '' AND operating_system = '' AND screen_size = ''
  AND pageviews > 0
  AND traffic = 0
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
      UPDATE traffic = 1, traffic_reasons = ['unknown_ua', 'no_device']
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
