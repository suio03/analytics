defmodule Plausible.PaymentsTest do
  use Plausible.DataCase, async: false
  use Oban.Testing, repo: Plausible.Repo
  alias Plausible.Payments
  alias Plausible.Payments.{Integration, Transaction, Event}

  setup do
    site = insert(:site)

    integration =
      Repo.insert!(%Integration{
        site_id: site.id,
        provider: "paddle",
        api_key: "private-api-key",
        webhook_secret: "private-signing-secret",
        webhook_token: Ecto.UUID.generate(),
        product_ids: ["pro_scribix"]
      })

    %{site: site, integration: integration}
  end

  defp attrs(id \\ "txn_example") do
    %{
      external_id: id,
      status: "paid",
      provider_status: "completed",
      kind: "renewal",
      currency: "USD",
      amount: 1299,
      paid_amount: 1299,
      net: 968,
      product_ids: ["pro_scribix"],
      occurred_at: ~U[2026-09-07 12:00:00.000000Z],
      items: [],
      details: %{}
    }
  end

  test "API keys are encrypted at rest", %{integration: i} do
    %{rows: [[key, secret]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT api_key, webhook_secret FROM payment_integrations WHERE id = $1",
        [i.id]
      )

    refute key == "private-api-key"
    refute secret == "private-signing-secret"
    assert Repo.get!(Integration, i.id).api_key == "private-api-key"
  end

  test "upserts count a payment once and reject unrelated or mixed-site products", %{
    site: site,
    integration: i
  } do
    assert :ok = Payments.store(i, attrs(), DateTime.utc_now())
    assert :ok = Payments.store(i, attrs(), DateTime.utc_now())

    assert :ok =
             Payments.store(
               i,
               %{attrs("txn_other") | product_ids: ["pro_muzix"]},
               DateTime.utc_now()
             )

    assert :ok =
             Payments.store(
               i,
               %{attrs("txn_mixed") | product_ids: ["pro_scribix", "pro_muzix"]},
               DateTime.utc_now()
             )

    result = Payments.list(site, Payments.filters(%{}))
    assert result.count == 1
    assert hd(result.summary).paid == 1299
    assert hd(result.summary).net == 968
  end

  test "site and environment boundaries apply to both detail and summary", %{
    site: site,
    integration: i
  } do
    other = insert(:site)
    Payments.store(i, attrs(), DateTime.utc_now())
    transaction = Repo.get_by!(Transaction, integration_id: i.id)

    assert_raise Ecto.NoResultsError, fn ->
      Payments.get_transaction!(other.id, transaction.id)
    end

    assert Payments.list(other, Payments.filters(%{})).count == 0
    assert Payments.list(site, Payments.filters(%{"environment" => "sandbox"})).count == 0
  end

  test "webhook retries persist one receipt and queue synchronization", %{integration: i} do
    event = %{
      "event_id" => "evt_example",
      "event_type" => "transaction.completed",
      "occurred_at" => "2026-09-07T12:00:00Z",
      "data" => %{"id" => "txn_example"}
    }

    assert {:ok, _} = Payments.receive_event(i, event)
    assert {:ok, _} = Payments.receive_event(i, event)
    assert Repo.aggregate(Event, :count) == 1
    assert_enqueued(worker: Plausible.Workers.SyncPayments, args: %{integration_id: i.id})
  end

  test "date, status, currency and literal search filters", %{site: site, integration: i} do
    attrs = Map.put(attrs(), :customer_email, "buyer_percent%@example.test")
    Payments.store(i, attrs, DateTime.utc_now())

    assert Payments.list(
             site,
             Payments.filters(%{"q" => "%", "currency" => "USD", "status" => "paid"})
           ).count == 1

    assert Payments.list(site, Payments.filters(%{"from" => "2026-09-08"})).count == 0
    assert Payments.list(site, Payments.filters(%{"currency" => "EUR"})).count == 0
    assert Payments.filters(%{"page" => "bad", "from" => "invalid"})["page"] == 1
  end

  test "failed paginated sync rolls back the snapshot and records a safe error", %{integration: i} do
    Application.put_env(:plausible, Plausible.Payments.Provider, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:plausible, Plausible.Payments.Provider) end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["after"] do
        Plug.Conn.send_resp(conn, 503, "provider-error-with-sensitive-data")
      else
        Req.Test.json(conn, %{
          "data" => [
            %{
              "id" => "txn_new",
              "status" => "draft",
              "currency_code" => "USD",
              "created_at" => "2026-09-07T00:00:00Z",
              "items" => [%{"price" => %{"product_id" => "pro_scribix"}}]
            }
          ],
          "meta" => %{"pagination" => %{"has_more" => true}}
        })
      end
    end)

    assert {:error, "Provider returned HTTP 503. Sync will retry."} =
             Plausible.Workers.SyncPayments.perform(%Oban.Job{args: %{"integration_id" => i.id}})

    assert Repo.aggregate(Transaction, :count) == 0
    assert Repo.get!(Integration, i.id).last_synced_at == nil
    refute Repo.get!(Integration, i.id).last_error =~ "sensitive-data"
  end

  test "summary keeps currencies separate and unpaid amounts out", %{site: site, integration: i} do
    Payments.store(i, attrs(), DateTime.utc_now())

    Payments.store(
      i,
      %{attrs("txn_eur") | currency: "EUR", paid_amount: 2000, net: nil},
      DateTime.utc_now()
    )

    Payments.store(
      i,
      %{attrs("txn_draft") | status: "incomplete", paid_amount: nil, net: nil},
      DateTime.utc_now()
    )

    summaries = Payments.list(site, Payments.filters(%{})).summary |> Map.new(&{&1.currency, &1})
    assert summaries["USD"].paid == 1299
    assert summaries["USD"].incomplete == 1
    assert summaries["EUR"].paid == 2000
    assert summaries["EUR"].net == nil
  end

  test "saving a connection validates mapping and rotating secrets preserves it", %{
    site: site,
    integration: i
  } do
    assert {:ok, updated} =
             Payments.save_integration(site.id, %{
               "provider" => "paddle",
               "environment" => "live",
               "api_key" => "rotated",
               "webhook_secret" => "",
               "product_ids" => ""
             })

    assert updated.api_key == "rotated"
    assert updated.webhook_secret == i.webhook_secret
    assert updated.product_ids == ["pro_scribix"]
    assert updated.webhook_token == i.webhook_token

    assert {:error, %Ecto.Changeset{}} =
             Payments.save_integration(site.id, %{
               "provider" => "creem",
               "environment" => "live",
               "api_key" => "key",
               "webhook_secret" => "secret",
               "product_ids" => ""
             })
  end

  test "product additions merge IDs, retain secrets and queue a historical sync", %{
    site: site,
    integration: i
  } do
    Payments.store(i, attrs(), DateTime.utc_now())
    new_order = %{attrs("txn_newproduct") | product_ids: ["pro_new"]}
    Payments.store(i, new_order, DateTime.utc_now())
    assert Repo.aggregate(Transaction, :count) == 1

    assert {:ok, updated} =
             Payments.save_integration(site.id, %{
               "provider" => "paddle",
               "environment" => "live",
               "product_ids" => "pro_new, pro_scribix\npro_new",
               "api_key" => "",
               "webhook_secret" => "",
               "webhook_token" => Ecto.UUID.generate()
             })

    assert updated.id == i.id
    assert updated.product_ids == ["pro_scribix", "pro_new"]
    assert updated.api_key == i.api_key
    assert updated.webhook_secret == i.webhook_secret
    assert updated.webhook_token == i.webhook_token
    assert_enqueued(worker: Plausible.Workers.SyncPayments, args: %{integration_id: i.id})

    assert {:ok, updated} =
             Payments.save_integration(site.id, %{
               "provider" => "paddle",
               "environment" => "live",
               "product_ids" => "pro_next, pro_new"
             })

    assert Repo.get!(Integration, i.id).product_ids == ["pro_scribix", "pro_new", "pro_next"]
    Payments.store(updated, new_order, DateTime.utc_now())
    Payments.store(updated, attrs(), DateTime.utc_now())
    assert Repo.aggregate(Transaction, :count) == 2
  end

  test "invalid additions leave the mapping and credentials unchanged", %{
    site: site,
    integration: i
  } do
    for products <- ["invalid-id", Enum.map(1..100, &"pro_#{&1}")] do
      assert {:error, changeset} =
               Payments.save_integration(site.id, %{
                 "provider" => "paddle",
                 "environment" => "live",
                 "api_key" => "should-not-be-saved",
                 "product_ids" => products
               })

      assert Keyword.has_key?(changeset.errors, :product_ids)
      saved = Repo.get!(Integration, i.id)
      assert saved.product_ids == i.product_ids
      assert saved.api_key == i.api_key
    end

    refute_enqueued(worker: Plausible.Workers.SyncPayments, args: %{integration_id: i.id})
  end
end
