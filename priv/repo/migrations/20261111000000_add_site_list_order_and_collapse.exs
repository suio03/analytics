defmodule Plausible.Repo.Migrations.AddSiteListOrderAndCollapse do
  use Ecto.Migration

  def change do
    alter table(:site_user_preferences) do
      # The user's own order on /sites (lower first); sites without one follow, by domain.
      add :position, :integer
      # Collapsed sites leave the grid for the compact row below it.
      add :collapsed, :boolean, null: false, default: false
    end
  end
end
