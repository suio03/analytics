defmodule PlausibleWeb.Api.PaymentWebhookController do
  use PlausibleWeb, :controller
  alias Plausible.Payments.{Integration, Signature}

  def webhook(conn, %{"token" => token}) do
    with {:ok, token} <- Ecto.UUID.cast(token),
         %Integration{} = integration <- Plausible.Repo.get_by(Integration, webhook_token: token),
         header <-
           if(integration.provider == "paddle", do: "paddle-signature", else: "creem-signature"),
         true <-
           Signature.valid?(
             integration.provider,
             integration.webhook_secret,
             conn.assigns[:payment_raw_body],
             List.first(get_req_header(conn, header))
           ),
         {:ok, payload} <- Jason.decode(conn.assigns.payment_raw_body),
         {:ok, _} <- Plausible.Payments.receive_event(integration, payload) do
      send_resp(conn, 200, "ok")
    else
      {:error, :invalid_event} -> send_resp(conn, 400, "Invalid event")
      {:error, _} -> send_resp(conn, 503, "Please retry")
      _ -> send_resp(conn, 401, "Invalid signature")
    end
  end
end
