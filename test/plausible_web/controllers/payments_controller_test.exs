defmodule PlausibleWeb.PaymentsControllerTest do
  use PlausibleWeb.ConnCase, async: false
  alias Plausible.Payments
  alias Plausible.Payments.Integration
  alias Plausible.Repo

  setup [:create_user, :log_in]

  setup %{user: user} do
    site = insert(:site, domain: "payments.example", members: [user])
    %{site: site}
  end

  test "owner sees the empty state and connection form", %{conn: conn} do
    assert get(conn, "/payments.example/transactions") |> html_response(200) =~
             "Connect a payment provider"

    html = get(conn, "/payments.example/transactions/settings") |> html_response(200)
    assert html =~ "Webhook signing secret"
    assert html =~ "New connection webhook URL"
  end

  test "public site and nonmembers cannot expose transactions", %{conn: conn} do
    other = insert(:site, domain: "other-payments.example", public: true)
    assert get(conn, "/#{other.domain}/transactions") |> html_response(404)
    assert get(conn, "/#{other.domain}/transactions/settings") |> html_response(404)
  end

  test "transaction list and details render amounts with no credentials", %{
    conn: conn,
    site: site
  } do
    i =
      Repo.insert!(%Integration{
        site_id: site.id,
        provider: "paddle",
        api_key: "never-render-this-api-key",
        webhook_secret: "never-render-this-signature",
        webhook_token: Ecto.UUID.generate(),
        product_ids: ["pro_scribix"]
      })

    Payments.store(
      i,
      %{
        external_id: "txn_visible",
        status: "paid",
        provider_status: "completed",
        kind: "renewal",
        currency: "USD",
        amount: 1299,
        paid_amount: 1299,
        net: 968,
        customer_email: "buyer@example.test",
        product_ids: ["pro_scribix"],
        occurred_at: DateTime.utc_now(),
        items: [%{"name" => "Virtuoso", "id" => "pro_scribix"}],
        details: %{}
      },
      DateTime.utc_now()
    )

    transaction = Repo.get_by!(Plausible.Payments.Transaction, integration_id: i.id)
    list = get(conn, "/payments.example/transactions")
    html = html_response(list, 200)
    assert html =~ "$12.99"
    assert html =~ "buyer@example.test"
    assert get_resp_header(list, "cache-control") == ["private, no-store"]
    detail = get(conn, "/payments.example/transactions/#{transaction.id}") |> html_response(200)
    assert detail =~ "Payment breakdown"
    assert detail =~ "$9.68"
    refute detail =~ i.api_key
    refute detail =~ i.webhook_secret
  end

  test "viewer membership cannot read payment pages or trigger sync", %{conn: conn, user: user} do
    site = insert(:site, domain: "viewer-payments.example", public: true)
    insert(:site_membership, site: site, user: user, role: :viewer)
    assert get(conn, "/#{site.domain}/transactions") |> html_response(404)
    assert post(conn, "/#{site.domain}/transactions/sync") |> html_response(404)
  end

  test "connected accounts expose additive forms and save to the selected environment", %{
    conn: conn,
    site: site
  } do
    for provider <- ["paddle", "creem"] do
      product = if provider == "paddle", do: "pro_existing", else: "prod_existing"
      added = if provider == "paddle", do: "pro_added", else: "prod_added"

      accounts =
        for environment <- ["live", "sandbox"] do
          Repo.insert!(%Integration{
            site_id: site.id,
            provider: provider,
            environment: environment,
            api_key: "never-render-this-api-key",
            webhook_secret: "never-render-this-signature",
            webhook_token: Ecto.UUID.generate(),
            product_ids: [product]
          })
        end

      html = get(conn, "/payments.example/transactions/settings") |> html_response(200)
      assert html =~ "Add products and sync"
      assert html =~ product
      refute html =~ "never-render-this-api-key"
      refute html =~ "never-render-this-signature"

      for account <- accounts do
        assert html =~ account.webhook_token
      end

      response =
        post(conn, "/payments.example/transactions/settings", %{
          "integration" => %{
            "provider" => provider,
            "environment" => "sandbox",
            "product_ids" => added
          }
        })

      assert redirected_to(response) == "/payments.example/transactions/settings"
      [live, sandbox] = Enum.map(accounts, &Repo.get!(Integration, &1.id))
      assert live.product_ids == [product]
      assert sandbox.product_ids == [product, added]
      assert sandbox.api_key == "never-render-this-api-key"
      assert sandbox.webhook_token == List.last(accounts).webhook_token
    end
  end
end
