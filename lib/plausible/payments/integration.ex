defmodule Plausible.Payments.Secret do
  @moduledoc "Encrypted payment credentials; uses the application's existing managed vault."
  use Cloak.Ecto.Binary, vault: Plausible.Auth.TOTP.Vault
end

defmodule Plausible.Payments.Integration do
  @moduledoc "Encrypted provider credentials and additive site product mapping."
  use Ecto.Schema
  import Ecto.Changeset

  schema "payment_integrations" do
    belongs_to(:site, Plausible.Site)
    field(:provider, :string)
    field(:environment, :string, default: "live")
    field(:api_key, Plausible.Payments.Secret, redact: true)
    field(:webhook_secret, Plausible.Payments.Secret, redact: true)
    field(:webhook_token, Ecto.UUID)
    field(:product_ids, {:array, :string}, default: [])
    field(:last_synced_at, :utc_datetime_usec)
    field(:last_error, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :provider,
      :environment,
      :api_key,
      :webhook_secret,
      :product_ids,
      :webhook_token
    ])
    |> validate_required([
      :provider,
      :environment,
      :api_key,
      :webhook_secret,
      :product_ids,
      :webhook_token
    ])
    |> validate_inclusion(:provider, ~w(paddle creem))
    |> validate_inclusion(:environment, ~w(live sandbox))
    |> require_products()
    |> validate_length(:product_ids, min: 1, max: 100)
    |> validate_change(:product_ids, fn :product_ids, ids ->
      if Enum.all?(ids, &Regex.match?(~r/^pro[d]?_[a-zA-Z0-9]+$/, &1)),
        do: [],
        else: [product_ids: "must contain valid product IDs (pro_… or prod_…)"]
    end)
    |> unique_constraint([:site_id, :provider, :environment])
    |> unique_constraint(:webhook_token)
  end

  defp require_products(changeset) do
    if get_field(changeset, :product_ids) in [nil, []] do
      add_error(changeset, :product_ids, "must include at least one product ID")
    else
      changeset
    end
  end
end
