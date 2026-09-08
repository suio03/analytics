defmodule Plausible.Repo.Migrations.AddSitePayments do
  use Ecto.Migration

  def change do
    create table(:payment_integrations) do
      add(:site_id, references(:sites, on_delete: :delete_all), null: false)
      add(:provider, :text, null: false)
      add(:environment, :text, null: false, default: "live")
      add(:api_key, :binary, null: false)
      add(:webhook_secret, :binary, null: false)
      add(:webhook_token, :uuid, null: false)
      add(:product_ids, {:array, :text}, null: false)
      add(:last_synced_at, :utc_datetime_usec)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:payment_integrations, [:site_id, :provider, :environment]))
    create(unique_index(:payment_integrations, [:webhook_token]))

    create table(:payment_transactions) do
      add(:integration_id, references(:payment_integrations, on_delete: :delete_all), null: false)
      add(:external_id, :text, null: false)
      add(:status, :text, null: false)
      add(:provider_status, :text, null: false)
      add(:kind, :text, null: false)
      add(:currency, :text, null: false)
      add(:amount, :bigint)
      add(:paid_amount, :bigint)
      add(:tax, :bigint)
      add(:fee, :bigint)
      add(:net, :bigint)
      add(:refunded_amount, :bigint)
      add(:customer_email, :text)
      add(:customer_id, :text)
      add(:country, :text)
      add(:subscription_id, :text)
      add(:product_ids, {:array, :text}, null: false, default: [])
      add(:items, {:array, :map}, null: false, default: [])
      add(:details, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:paid_at, :utc_datetime_usec)
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:payment_transactions, [:integration_id, :external_id]))
    create(index(:payment_transactions, [:integration_id, :occurred_at]))

    create table(:payment_events) do
      add(:integration_id, references(:payment_integrations, on_delete: :delete_all), null: false)
      add(:external_id, :text, null: false)
      add(:event_type, :text, null: false)
      add(:transaction_id, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:payment_events, [:integration_id, :external_id]))
    create(index(:payment_events, [:integration_id, :transaction_id]))
  end
end
