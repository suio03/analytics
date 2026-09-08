defmodule PlausibleWeb.Api.PaymentWebhookControllerTest do
  use PlausibleWeb.ConnCase, async: false
  alias Plausible.Payments.{Integration, Event}
  alias Plausible.Repo

  setup do
    site = insert(:site)

    integration =
      Repo.insert!(%Integration{
        site_id: site.id,
        provider: "paddle",
        api_key: "test-key",
        webhook_secret: "signing-secret",
        webhook_token: Ecto.UUID.generate(),
        product_ids: ["pro_scribix"]
      })

    %{integration: integration}
  end

  test "verifies raw JSON, accepts retries once and rejects tampered bytes", %{
    conn: conn,
    integration: i
  } do
    now = System.system_time(:second)

    body =
      Jason.encode!(%{
        event_id: "evt_signed",
        event_type: "transaction.completed",
        occurred_at: DateTime.to_iso8601(DateTime.utc_now()),
        data: %{id: "txn_1"}
      })

    signature =
      :crypto.mac(:hmac, :sha256, i.webhook_secret, "#{now}:#{body}")
      |> Base.encode16(case: :lower)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("paddle-signature", "ts=#{now};h1=#{signature}")

    path = "/api/payments/webhooks/#{i.webhook_token}"
    assert post(conn, path, body) |> response(200) == "ok"
    assert post(conn, path, body) |> response(200) == "ok"
    assert Repo.aggregate(Event, :count) == 1
    assert post(conn, path, body <> " ") |> response(401) == "Invalid signature"
  end
end
