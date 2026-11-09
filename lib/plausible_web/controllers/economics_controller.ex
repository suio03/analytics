defmodule PlausibleWeb.EconomicsController do
  use PlausibleWeb, :controller
  alias Plausible.Economics

  plug(PlausibleWeb.RequireAccountPlug)
  plug(PlausibleWeb.Plugs.AuthorizeSiteAccess, [:owner, :admin, :super_admin])
  plug(:private_response)

  def index(conn, params) do
    site = conn.assigns.site
    source = Economics.source(site.id)
    days = days(params["days"])

    {report, error} =
      case source && Economics.fetch(source, days) do
        nil -> {nil, nil}
        {:ok, report} -> {report, nil}
        {:error, message} -> {nil, message}
      end

    render(conn, "index.html",
      title: "Economics · #{site.domain}",
      source: source,
      report: report,
      error: error,
      days: days
    )
  end

  def settings(conn, _), do: render_settings(conn)

  def save(conn, %{"source" => attrs}) do
    case Economics.save_source(conn.assigns.site.id, Map.take(attrs, ~w(url token))) do
      {:ok, _} ->
        conn
        |> put_flash(:success, "Cost report endpoint saved.")
        |> redirect(to: "/#{URI.encode_www_form(conn.assigns.site.domain)}/economics")

      {:error, changeset} ->
        message =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        conn |> put_status(422) |> render_settings(message)
    end
  end

  defp days(param) when is_binary(param) do
    case Integer.parse(param) do
      {n, ""} when n in 7..180 -> n
      _ -> 56
    end
  end

  defp days(_), do: 56

  defp render_settings(conn, error \\ nil) do
    render(conn, "settings.html",
      title: "Cost report endpoint · #{conn.assigns.site.domain}",
      source: Economics.source(conn.assigns.site.id),
      error: error
    )
  end

  defp private_response(conn, _), do: put_resp_header(conn, "cache-control", "private, no-store")
end
