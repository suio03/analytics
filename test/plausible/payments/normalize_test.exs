defmodule Plausible.Payments.NormalizeTest do
  use ExUnit.Case, async: true
  alias Plausible.Payments.Normalize

  def paddle(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "txn_example",
        "status" => "completed",
        "currency_code" => "USD",
        "created_at" => "2026-09-07T18:41:00Z",
        "origin" => "subscription_recurring",
        "items" => [
          %{
            "quantity" => 1,
            "price" => %{
              "product_id" => "pro_scribix",
              "name" => "Virtuoso",
              "billing_cycle" => %{"interval" => "month"},
              "unit_price" => %{"amount" => "1299"}
            }
          }
        ],
        "details" => %{
          "totals" => %{
            "grand_total" => "1299",
            "tax" => "216",
            "fee" => "115",
            "earnings" => "968"
          }
        },
        "payments" => [
          %{
            "status" => "captured",
            "amount" => "1299",
            "captured_at" => "2026-09-07T18:41:00Z",
            "method_details" => %{
              "type" => "card",
              "card" => %{"type" => "visa", "last4" => "1632"}
            }
          }
        ]
      },
      overrides
    )
  end

  test "completed payment preserves provider amounts and renewal type" do
    t = Normalize.paddle(paddle())
    assert {t.amount, t.paid_amount, t.tax, t.fee, t.net} == {1299, 1299, 216, 115, 968}
    assert t.kind == "renewal"
    assert t.status == "paid"
    assert t.details["card_last4"] == "1632"
  end

  test "an incomplete order has no inferred paid amount or earnings" do
    t =
      Normalize.paddle(
        paddle(%{
          "status" => "draft",
          "payments" => [],
          "details" => %{"totals" => %{"grand_total" => "1299"}}
        })
      )

    assert t.status == "incomplete"
    assert t.paid_amount == nil
    assert t.net == nil
    assert t.paid_at == nil
  end

  test "pending refunds are excluded, approved partial refunds are included" do
    pending = %{
      "action" => "refund",
      "status" => "pending_approval",
      "totals" => %{"total" => "500"}
    }

    assert Normalize.paddle(paddle(%{"adjustments" => [pending]})).status == "paid"
    t = Normalize.paddle(paddle(%{"adjustments" => [Map.put(pending, "status", "approved")]}))
    assert t.status == "partially_refunded"
    assert t.refunded_amount == 500
  end

  test "Creem does not invent earnings, payment dates or first purchase classification" do
    t =
      Normalize.creem(
        %{
          "id" => "tran_1",
          "status" => "paid",
          "type" => "invoice",
          "amount" => 1000,
          "amount_paid" => 1200,
          "currency" => "EUR",
          "tax_amount" => 200,
          "created_at" => 1_788_804_060_000
        },
        %{"id" => "prod_pixfy", "name" => "Pixfy Pro"},
        %{"email" => "buyer@example.test"}
      )

    assert t.paid_amount == 1200
    assert t.tax == 200
    assert t.net == nil && t.fee == nil && t.paid_at == nil
    assert t.kind == "subscription"
    assert t.product_ids == ["prod_pixfy"]
  end
end
