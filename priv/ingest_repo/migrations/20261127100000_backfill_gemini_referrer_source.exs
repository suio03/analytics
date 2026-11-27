defmodule Plausible.IngestRepo.Migrations.BackfillGeminiReferrerSource do
  @moduledoc """
  Moves visits from Gemini stored before c15a86a6 to the "Gemini" source.

  The referrer database matched gemini.google.com (and bard.google.com) to
  "Google", so those visits were stored as Google with the Organic Search
  channel. `Plausible.Ingestion.Event` now records them as "Gemini" with the
  Referral channel; this applies the same to the rows stored before. Visits
  tagged `utm_source=gemini` were stored as lowercase "gemini"; they become
  "Gemini" and keep their channel. Events carry their own copy of the session's
  referrer columns, so both tables are updated with the same condition.
  """

  use Ecto.Migration

  @condition """
  (referrer_source = 'Google'
    AND (startsWith(referrer, 'gemini.google.com') OR startsWith(referrer, 'bard.google.com')))
  OR referrer_source = 'gemini'
  """

  def up do
    for table <- ["events_v2", "sessions_v2"] do
      repo().query!(
        """
        ALTER TABLE #{table}
        #{Plausible.MigrationUtils.on_cluster_statement(table)}
        UPDATE referrer_source = 'Gemini',
          channel = if(referrer_source = 'Google', 'Referral', channel)
        WHERE #{@condition}
        """,
        %{},
        settings: [mutations_sync: 2]
      )
    end
  end

  def down, do: :ok
end
