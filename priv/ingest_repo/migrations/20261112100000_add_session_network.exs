defmodule Plausible.IngestRepo.Migrations.AddSessionNetwork do
  @moduledoc """
  Adds `network` to sessions: a salted hash of the visitor's /24 (IPv6 /48)
  network, see `Plausible.Ingestion.Network`. 0 for sessions stored before.
  """

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE sessions_v2
    #{Plausible.MigrationUtils.on_cluster_statement("sessions_v2")}
    ADD COLUMN IF NOT EXISTS network UInt64 DEFAULT 0
    """
  end

  def down do
    execute """
    ALTER TABLE sessions_v2
    #{Plausible.MigrationUtils.on_cluster_statement("sessions_v2")}
    DROP COLUMN IF EXISTS network
    """
  end
end
