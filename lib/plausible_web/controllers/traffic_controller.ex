defmodule PlausibleWeb.TrafficController do
  use PlausibleWeb, :controller

  plug(PlausibleWeb.RequireAccountPlug)
  plug(PlausibleWeb.Plugs.AuthorizeSiteAccess, [:owner, :admin, :super_admin])
  plug(:private_response)

  @default_days 7
  @windows [7, 28, 90]

  def index(conn, params), do: render_page(conn, days(params["days"]), nil)

  # Written summary of the same facts, generated on request (it costs an API call).
  def report(conn, params) do
    days = days(params["days"])
    language = if params["language"] == "zh", do: "Simplified Chinese", else: "English"

    render_page(
      conn,
      days,
      Plausible.TrafficReport.generate(conn.assigns.site, days, language: language)
    )
  end

  defp render_page(conn, days, report) do
    site = conn.assigns.site

    render(conn, "index.html",
      title: "Traffic quality · #{site.domain}",
      days: days,
      windows: @windows,
      quality: Plausible.TrafficQuality.report(site.id, days),
      edge: Plausible.EdgeRequests.report(site.id, days),
      edge_enabled: Plausible.EdgeRequests.enabled?(),
      alerts: Plausible.TrafficAlerts.evaluate(site.id),
      alerts_day: Date.add(Date.utc_today(), -1),
      report: report,
      report_enabled: Plausible.TrafficReport.enabled?()
    )
  end

  defp days(param) when is_binary(param) do
    case Integer.parse(param) do
      {n, ""} when n in @windows -> n
      _ -> @default_days
    end
  end

  defp days(_), do: @default_days

  defp private_response(conn, _), do: put_resp_header(conn, "cache-control", "private, no-store")
end
