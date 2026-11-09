defmodule Plausible.Repo.Migrations.AddSiteEconomics do
  use Ecto.Migration

  def change do
    create table(:economics_sources) do
      add(:site_id, references(:sites, on_delete: :delete_all), null: false)
      add(:url, :text, null: false)
      add(:token, :binary, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:economics_sources, [:site_id]))
  end
end
