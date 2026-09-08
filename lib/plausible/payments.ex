defmodule Plausible.Payments do
  @moduledoc "Site-scoped payment ledger, separate from anonymous analytics events."
  import Ecto.Query
  alias Plausible.Repo
  alias Plausible.Payments.{Integration, Transaction, Event, Normalize}

  def integrations(site_id),
    do: Repo.all(from(i in Integration, where: i.site_id == ^site_id, order_by: i.provider))

  def save_integration(site_id, attrs) do
    attrs =
      Map.update(attrs, "product_ids", [], fn ids ->
        if is_binary(ids),
          do: ids |> String.split(~r/[\s,]+/, trim: true) |> Enum.uniq(),
          else: ids
      end)

    existing =
      Repo.get_by(Integration,
        site_id: site_id,
        provider: attrs["provider"],
        environment: attrs["environment"] || "live"
      )

    integration = existing || %Integration{site_id: site_id, webhook_token: Ecto.UUID.generate()}

    attrs =
      if existing, do: attrs, else: Map.put_new(attrs, "webhook_token", integration.webhook_token)

    # Mapping and environment are fixed after connection to protect historical site attribution.
    attrs =
      if existing,
        do:
          Map.take(attrs, ~w(api_key webhook_secret))
          |> Map.reject(fn {_, v} -> v in [nil, ""] end),
        else: attrs

    Repo.transaction(fn ->
      case integration |> Integration.changeset(attrs) |> Repo.insert_or_update() do
        {:ok, saved} ->
          enqueue_or_rollback(saved.id)
          saved

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def enqueue(id),
    do: %{"integration_id" => id} |> Plausible.Workers.SyncPayments.new() |> Oban.insert()

  def store(integration, attrs, observed_at) do
    # Do not allocate an entire multi-site basket to one site.
    if attrs.product_ids != [] && Enum.all?(attrs.product_ids, &(&1 in integration.product_ids)) do
      if is_binary(attrs.external_id) && is_binary(attrs.currency) && attrs.occurred_at do
        now = DateTime.utc_now()

        attrs =
          Map.merge(attrs, %{
            integration_id: integration.id,
            observed_at: observed_at,
            inserted_at: now,
            updated_at: now
          })

        {_, _} =
          Repo.insert_all(Transaction, [attrs],
            conflict_target: [:integration_id, :external_id],
            on_conflict:
              {:replace, Map.keys(attrs) -- [:integration_id, :external_id, :inserted_at]}
          )

        :ok
      else
        {:error, :invalid_transaction}
      end
    else
      :ok
    end
  end

  def receive_event(integration, payload) do
    id = payload["event_id"] || payload["id"]
    type = payload["event_type"] || payload["eventType"]
    occurred_at = Normalize.datetime(payload["occurred_at"] || payload["created_at"])
    object = payload["data"] || payload["object"] || %{}

    transaction_id =
      cond do
        integration.provider == "paddle" && is_binary(type) &&
            String.starts_with?(type, "transaction.") ->
          object["id"]

        integration.provider == "paddle" ->
          object["transaction_id"]

        type == "checkout.completed" ->
          Normalize.id(get_in(object, ["order", "transaction"]))

        type == "subscription.paid" ->
          object["last_transaction_id"] || Normalize.id(object["last_transaction"])

        true ->
          Normalize.id(object["transaction"])
      end

    if is_binary(id) && is_binary(type) && occurred_at do
      store_event(integration.id, id, type, transaction_id, occurred_at)
    else
      {:error, :invalid_event}
    end
  end

  defp store_event(integration_id, id, type, transaction_id, occurred_at) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {count, _} =
        Repo.insert_all(
          Event,
          [
            %{
              integration_id: integration_id,
              external_id: id,
              event_type: type,
              transaction_id: transaction_id,
              occurred_at: occurred_at,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:integration_id, :external_id]
        )

      if count == 1, do: enqueue_or_rollback(integration_id)
    end)
  end

  defp enqueue_or_rollback(integration_id) do
    case enqueue(integration_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def filters(params) do
    %{
      "q" => String.slice(to_string(params["q"] || ""), 0, 200),
      "status" => params["status"] || "",
      "provider" => params["provider"] || "",
      "kind" => params["kind"] || "",
      "product" => params["product"] || "",
      "currency" => params["currency"] || "",
      "environment" => if(params["environment"] == "sandbox", do: "sandbox", else: "live"),
      "from" => valid_date(params["from"]),
      "to" => valid_date(params["to"]),
      "page" =>
        case Integer.parse(to_string(params["page"] || "1")) do
          {n, ""} when n > 0 -> min(n, 100_000)
          _ -> 1
        end
    }
  end

  def list(site, filters) do
    query = query(site, filters)

    rows =
      Repo.all(
        from(t in query,
          order_by: [desc: t.occurred_at, desc: t.id],
          limit: 26,
          offset: ^((filters["page"] - 1) * 25),
          preload: [:integration]
        )
      )

    %{
      rows: Enum.take(rows, 25),
      has_more: length(rows) > 25,
      count: Repo.aggregate(query, :count),
      summary: summary(query)
    }
  end

  def get_transaction!(site_id, id) do
    Repo.one!(
      from(t in Transaction,
        join: i in Integration,
        on: i.id == t.integration_id,
        where: i.site_id == ^site_id and t.id == ^id,
        preload: [integration: i]
      )
    )
  end

  def events(transaction) do
    Repo.all(
      from(e in Event,
        where:
          e.integration_id == ^transaction.integration_id and
            e.transaction_id == ^transaction.external_id,
        order_by: [desc: e.occurred_at],
        limit: 100
      )
    )
  end

  def options(site_id) do
    Repo.all(
      from(t in Transaction,
        join: i in Integration,
        on: i.id == t.integration_id,
        where: i.site_id == ^site_id,
        distinct: true,
        select: t.currency
      )
    )
    |> Enum.sort()
  end

  defp query(site, filters) do
    base =
      from(t in Transaction,
        join: i in Integration,
        on: i.id == t.integration_id,
        where: i.site_id == ^site.id and i.environment == ^filters["environment"]
      )

    Enum.reduce(filters, base, fn
      {"q", ""}, q ->
        q

      {"q", value}, q ->
        pattern =
          "%" <>
            (value
             |> String.replace("\\", "\\\\")
             |> String.replace("%", "\\%")
             |> String.replace("_", "\\_")) <> "%"

        from(t in q, where: ilike(t.customer_email, ^pattern) or ilike(t.external_id, ^pattern))

      {"status", value}, q when value != "" ->
        from(t in q, where: t.status == ^value)

      {"kind", value}, q when value != "" ->
        from(t in q, where: t.kind == ^value)

      {"currency", value}, q when value != "" ->
        from(t in q, where: t.currency == ^value)

      {"provider", value}, q when value != "" ->
        from([t, i] in q, where: i.provider == ^value)

      {"product", value}, q when value != "" ->
        from(t in q, where: ^value in t.product_ids)

      {"from", value}, q when value != "" ->
        boundary =
          DateTime.new!(Date.from_iso8601!(value), ~T[00:00:00], site.timezone)
          |> DateTime.shift_zone!("Etc/UTC")

        from(t in q, where: t.occurred_at >= ^boundary)

      {"to", value}, q when value != "" ->
        boundary =
          DateTime.new!(Date.add(Date.from_iso8601!(value), 1), ~T[00:00:00], site.timezone)
          |> DateTime.shift_zone!("Etc/UTC")

        from(t in q, where: t.occurred_at < ^boundary)

      _, q ->
        q
    end)
  end

  defp summary(query) do
    Repo.all(
      from(t in query,
        group_by: t.currency,
        select: %{
          currency: t.currency,
          paid: sum(t.paid_amount),
          refunded: sum(t.refunded_amount),
          net: sum(t.net),
          net_known: count(t.net),
          paid_known: count(t.paid_amount),
          successful: filter(count(t.id), t.status in ["paid", "partially_refunded", "refunded"]),
          incomplete: filter(count(t.id), t.status == "incomplete")
        }
      )
    )
    |> Enum.map(fn summary ->
      Map.new(summary, fn
        {key, %Decimal{} = value} -> {key, Decimal.to_integer(value)}
        pair -> pair
      end)
    end)
  end

  defp valid_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _} -> value
      _ -> ""
    end
  end

  defp valid_date(_), do: ""
end
