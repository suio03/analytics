defmodule Plausible.IngestRepo.Migrations.CreateReplayChunks do
  use Ecto.Migration

  # Session recordings: rrweb events in the batches the recorder posts. A session's recording
  # is its page loads (load_id) in time order, each load's batches in seq order. Kept 30 days.
  def change do
    execute """
            CREATE TABLE IF NOT EXISTS replay_chunks
            (
                `site_id` UInt64,
                `session_id` String,
                `visitor_id` String,
                `load_id` String,
                `seq` UInt32,
                `started_at` DateTime64(3, 'UTC'),
                `ended_at` DateTime64(3, 'UTC'),
                `received_at` DateTime64(3, 'UTC') DEFAULT now64(3),
                `events` UInt32,
                `data` String CODEC(ZSTD(3))
            )
            ENGINE = ReplacingMergeTree(received_at)
            PARTITION BY toYYYYMMDD(received_at)
            ORDER BY (site_id, session_id, load_id, seq)
            TTL toDateTime(received_at) + INTERVAL 30 DAY DELETE
            SETTINGS ttl_only_drop_parts = 1
            """,
            """
            DROP TABLE IF EXISTS replay_chunks SYNC
            """
  end
end
