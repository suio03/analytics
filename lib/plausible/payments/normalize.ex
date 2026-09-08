defmodule Plausible.Payments.Normalize do
  @moduledoc "Converts provider records into minor-unit amounts without estimating missing earnings."

  def paddle(data) do
    totals = get_in(data, ["details", "totals"]) || %{}
    adjusted = get_in(data, ["details", "adjusted_totals"]) || totals
    payments = Enum.filter(data["payments"] || [], &(&1["status"] == "captured"))
    payment = List.first(payments) || %{}
    method = payment["method_details"] || %{}
    refunded = get_in(data, ["adjustments_totals", "refund"]) |> integer()
    # Only approved refunds change transaction status, never pending requests.
    refunded = refunded || approved_refunds(data["adjustments"] || [])
    amount = integer(totals["grand_total"] || totals["total"])

    paid =
      if payments == [],
        do: nil,
        else: Enum.sum(Enum.map(payments, &(integer(&1["amount"]) || 0)))

    raw_status = data["status"]

    disputed =
      Enum.any?(
        data["adjustments"] || [],
        &(&1["action"] == "chargeback" && &1["status"] == "approved")
      )

    items =
      Enum.map(data["items"] || [], fn item ->
        product = item["product"] || %{}
        price = item["price"] || %{}

        %{
          "id" => product["id"] || price["product_id"],
          "name" =>
            product["name"] || price["name"] || price["description"] || price["product_id"],
          "quantity" => item["quantity"],
          "unit_amount" => integer(get_in(price, ["unit_price", "amount"]))
        }
      end)

    %{
      external_id: data["id"],
      provider_status: raw_status,
      status: if(disputed, do: "disputed", else: status(raw_status, refunded, paid || amount)),
      kind:
        cond do
          data["origin"] == "subscription_recurring" ->
            "renewal"

          data["origin"] in ~w(subscription_update subscription_charge) ->
            "subscription_change"

          Enum.any?(data["items"] || [], &(get_in(&1, ["price", "billing_cycle"]) != nil)) ->
            "first_purchase"

          true ->
            "one_time"
        end,
      currency: data["currency_code"],
      amount: amount,
      paid_amount: paid,
      tax: integer(totals["grand_total_tax"] || totals["tax"]),
      fee: integer(adjusted["fee"]),
      net: integer(adjusted["earnings"]),
      refunded_amount: refunded,
      customer_email: get_in(data, ["customer", "email"]),
      customer_id: data["customer_id"],
      country: get_in(data, ["address", "country_code"]),
      subscription_id: data["subscription_id"],
      product_ids: Enum.map(items, & &1["id"]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      items: items,
      occurred_at: datetime(data["created_at"]),
      paid_at: datetime(payment["captured_at"]),
      details: %{
        "invoice_number" => data["invoice_number"],
        "billing_period" => data["billing_period"],
        "payment_method" => method["type"],
        "card_brand" => get_in(method, ["card", "type"]),
        "card_last4" => get_in(method, ["card", "last4"]),
        "user_id" =>
          get_in(data, ["custom_data", "userId"]) || get_in(data, ["custom_data", "user_id"])
      }
    }
  end

  # Product is supplied by the provider's product-scoped search, not inferred from the customer.
  def creem(data, product, customer) do
    amount = integer(data["amount_paid"] || data["amount"])
    paid = integer(data["amount_paid"])
    refunded = integer(data["refunded_amount"]) || 0

    %{
      external_id: data["id"],
      provider_status: data["status"],
      status: status(data["status"], refunded, paid || amount),
      kind: if(data["type"] == "invoice", do: "subscription", else: "one_time"),
      currency: data["currency"],
      amount: amount,
      paid_amount: paid,
      tax: integer(data["tax_amount"]),
      fee: nil,
      net: nil,
      refunded_amount: refunded,
      customer_email: customer["email"],
      customer_id: id(data["customer"]),
      country: data["tax_country"],
      subscription_id: id(data["subscription"]),
      product_ids: [product["id"]],
      items: [
        %{
          "id" => product["id"],
          "name" => product["name"] || product["id"],
          "quantity" => nil,
          "unit_amount" => nil
        }
      ],
      occurred_at: datetime(data["created_at"]),
      paid_at: nil,
      details: %{
        "order_id" => id(data["order"]),
        "description" => data["description"],
        "billing_period" => %{
          "starts_at" => iso(data["period_start"]),
          "ends_at" => iso(data["period_end"])
        }
      }
    }
  end

  defp approved_refunds(adjustments) do
    adjustments
    |> Enum.filter(&(&1["action"] == "refund" && &1["status"] == "approved"))
    |> Enum.map(&(integer(get_in(&1, ["totals", "total"])) || 0))
    |> Enum.map(&abs/1)
    |> Enum.sum()
  end

  defp status(raw, refunded, amount) do
    cond do
      raw == "chargeback" ->
        "disputed"

      raw == "refunded" || (refunded > 0 && is_integer(amount) && refunded >= amount) ->
        "refunded"

      raw == "partially_refunded" || refunded > 0 ->
        "partially_refunded"

      raw in ~w(completed paid) ->
        "paid"

      raw == "past_due" ->
        "failed"

      raw in ~w(canceled cancelled) ->
        "canceled"

      true ->
        "incomplete"
    end
  end

  def integer(value) when is_integer(value), do: value

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  def integer(_), do: nil

  def datetime(nil), do: nil

  def datetime(value) when is_integer(value) do
    unit = if abs(value) > 100_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, date} -> usec(date)
      _ -> nil
    end
  end

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> usec(date)
      _ -> nil
    end
  end

  def datetime(_), do: nil
  defp usec(date), do: %{date | microsecond: {elem(date.microsecond, 0), 6}}

  defp iso(value) do
    case datetime(value) do
      nil -> nil
      date -> DateTime.to_iso8601(date)
    end
  end

  def id(%{"id" => id}), do: id
  def id(id) when is_binary(id), do: id
  def id(_), do: nil
end
