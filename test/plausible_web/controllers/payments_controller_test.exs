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
end
