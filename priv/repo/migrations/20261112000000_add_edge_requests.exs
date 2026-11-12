defmodule Plausible.Repo.Migrations.AddEdgeRequests do
  use Ecto.Migration

  def change do
    create table(:edge_requests) do
      add(:site_id, references(:sites, on_delete: :delete_all), null: false)
      add(:date, :date, null: false)
      add(:agent, :text, null: false)
      add(:category, :text, null: false)
      add(:requests, :bigint, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:edge_requests, [:site_id, :date, :agent]))
  end
end
