defmodule PlausibleWeb.PaymentsController do
  use PlausibleWeb, :controller
  alias Plausible.Payments

  plug(PlausibleWeb.RequireAccountPlug)
  plug(PlausibleWeb.Plugs.AuthorizeSiteAccess, [:owner, :admin, :super_admin])
  plug(:private_response)

  def index(conn, params) do
    site = conn.assigns.site
    filters = Payments.filters(params)

    render(conn, "index.html",
      title: "Transactions · #{site.domain}",
      filters: filters,
      result: Payments.list(site, filters),
      integrations: Payments.integrations(site.id),
      currencies: Payments.options(site.id)
    )
  end

  def show(conn, %{"id" => id}) do
    transaction = Payments.get_transaction!(conn.assigns.site.id, id)

    render(conn, "show.html",
      title: "Transaction · #{conn.assigns.site.domain}",
      transaction: transaction,
      events: Payments.events(transaction)
    )
  end

  def settings(conn, _) do
    render_settings(conn)
  end

  def save(conn, %{"integration" => attrs}) do
    case Payments.save_integration(conn.assigns.site.id, attrs) do
      {:ok, _} ->
        conn
        |> put_flash(:success, "Payment connection saved. Historical sync has been queued.")
        |> redirect(to: path(conn, "/settings"))

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
            Enum.reduce(opts, message, fn {key, value}, message ->
              String.replace(message, "%{#{key}}", to_string(value))
            end)
          end)

        message =
          Enum.map_join(errors, "; ", fn {field, messages} ->
            "#{field}: #{Enum.join(messages, ", ")}"
          end)

        conn |> put_status(422) |> render_settings(message)

      {:error, _} ->
        conn |> put_status(503) |> render_settings("Could not queue the sync. Please try again.")
    end
  end

  def sync(conn, _) do
    integrations = Payments.integrations(conn.assigns.site.id)
    results = Enum.map(integrations, &Payments.enqueue(&1.id))

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      conn
      |> put_flash(
        :success,
        "Sync queued. Refresh this page shortly to see the latest transactions."
      )
      |> redirect(to: path(conn))
    else
      conn
      |> put_flash(:error, "Could not queue sync. Please try again.")
      |> redirect(to: path(conn))
    end
  end

  defp render_settings(conn, error \\ nil) do
    render(conn, "settings.html",
      title: "Payment connections · #{conn.assigns.site.domain}",
      integrations: Payments.integrations(conn.assigns.site.id),
      error: error,
      webhook_tokens: %{"paddle" => Ecto.UUID.generate(), "creem" => Ecto.UUID.generate()}
    )
  end

  defp path(conn, suffix \\ ""),
    do: "/#{URI.encode_www_form(conn.assigns.site.domain)}/transactions#{suffix}"

  defp private_response(conn, _), do: put_resp_header(conn, "cache-control", "private, no-store")
end
