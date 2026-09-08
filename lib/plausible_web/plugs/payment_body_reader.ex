defmodule PlausibleWeb.Plugs.PaymentBodyReader do
  @moduledoc false
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        conn =
          if String.starts_with?(conn.request_path, "/api/payments/webhooks/") do
            Plug.Conn.assign(
              conn,
              :payment_raw_body,
              (conn.assigns[:payment_raw_body] || "") <> body
            )
          else
            conn
          end

        {status, body, conn}

      other ->
        other
    end
  end
end
