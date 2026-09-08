defmodule Plausible.Payments.Transaction do
  use Ecto.Schema

  schema "payment_transactions" do
    belongs_to(:integration, Plausible.Payments.Integration)
    field(:external_id, :string)
    field(:status, :string)
    field(:provider_status, :string)
    field(:kind, :string)
    field(:currency, :string)
    field(:amount, :integer)
    field(:paid_amount, :integer)
    field(:tax, :integer)
    field(:fee, :integer)
    field(:net, :integer)
    field(:refunded_amount, :integer)
    field(:customer_email, :string, redact: true)
    field(:customer_id, :string)
    field(:country, :string)
    field(:subscription_id, :string)
    field(:product_ids, {:array, :string}, default: [])
    field(:items, {:array, :map}, default: [])
    field(:details, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)
    field(:paid_at, :utc_datetime_usec)
    field(:observed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Plausible.Payments.Event do
  use Ecto.Schema

  schema "payment_events" do
    belongs_to(:integration, Plausible.Payments.Integration)
    field(:external_id, :string)
    field(:event_type, :string)
    field(:transaction_id, :string)
    field(:occurred_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
