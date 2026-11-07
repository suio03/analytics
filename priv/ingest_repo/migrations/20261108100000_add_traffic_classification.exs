defmodule Plausible.IngestRepo.Migrations.AddTrafficClassification do
  @moduledoc """
  Adds traffic classification columns.

  `traffic` is 0 for humans, 1 for suspicious traffic and 2 for bots. The class
  is decided when a session starts and copied to every event of that session.
  `traffic_reasons` lists the signals that led to a non-human class, and
  `interacted` records whether the tracker reported a real user interaction.
  """

  use Ecto.Migration

  def up do
    add_column("events_v2", "traffic", "UInt8 DEFAULT 0")
    add_column("sessions_v2", "traffic", "UInt8 DEFAULT 0")
    add_column("sessions_v2", "traffic_reasons", "Array(LowCardinality(String))")
    add_column("sessions_v2", "interacted", "UInt8 DEFAULT 0")
  end

  def down do
    drop_column("events_v2", "traffic")
    drop_column("sessions_v2", "traffic")
    drop_column("sessions_v2", "traffic_reasons")
    drop_column("sessions_v2", "interacted")
  end

  defp add_column(table, column, type) do
    execute """
    ALTER TABLE #{table}
    #{Plausible.MigrationUtils.on_cluster_statement(table)}
    ADD COLUMN IF NOT EXISTS #{column} #{type}
    """
  end

  defp drop_column(table, column) do
    execute """
    ALTER TABLE #{table}
    #{Plausible.MigrationUtils.on_cluster_statement(table)}
    DROP COLUMN IF EXISTS #{column}
    """
  end
end
