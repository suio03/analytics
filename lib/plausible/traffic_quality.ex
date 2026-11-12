defmodule Plausible.TrafficQuality do
  @moduledoc """
  How a site's sessions were classified (see `Plausible.Ingestion.Traffic`),
  by UTC day and by reason, including evidence-only reasons that don't change
  the class. Feeds the Traffic quality page and its admin API.
  """

  alias Plausible.ClickhouseRepo

  @classes %{0 => "human", 1 => "suspicious", 2 => "bot"}

  # {description, effect} for each classifier reason.
  @reasons %{
    "bot_ua" => {"User agent of a known crawler", :bot},
    "headless_ua" => {"Headless browser or HTTP library", :bot},
    "webdriver" => {"The tracker saw navigator.webdriver", :bot},
    "automation_globals" => {"The tracker saw automation globals", :bot},
    "forged_search_referrer" =>
      {"Search engine referrer no real click sends (http://, or Google with a query)", :strong},
    "oneshot_farm" =>
      {"One of 30+ one-page visitors from one network on one day (daily farm job)", :strong},
    "unknown_ua" => {"Browser can't be identified", :weak},
    "no_device" => {"Device type can't be identified", :weak},
    "datacenter_ip" => {"Cloud provider network", :weak},
    "search_ref_datacenter" => {"Search engine referrer from a cloud provider network", :weak},
    "outdated_browser" => {"Desktop Chrome six or more releases old", :weak},
    "no_referrer" => {"Outdated browser landing without referrer or campaign", :weak},
    "zero_window" => {"Zero-sized window", :weak},
    "no_languages" => {"No browser languages", :weak},
    "no_sec_fetch" =>
      {"No Sec-Fetch-* request headers, which every current browser sends", :evidence},
    "no_client_hints" => {"Chromium 90+ without Sec-CH-UA client hints", :evidence}
  }

  @doc "`{description, effect}` of a classifier reason; effect is :bot, :strong, :weak or :evidence."
  def reason_info(reason), do: Map.get(@reasons, reason, {reason, :weak})

  @doc """
  Sessions and pageviews per class and UTC day, and sessions per reason and
  class, for the `days` UTC days ending `today`.
  """
  def report(site_id, days, today \\ Date.utc_today()) do
    since = Date.add(today, -(days - 1))
    params = %{"site" => site_id, "since" => since, "until" => Date.add(today, 1)}

    %{rows: daily} =
      ClickhouseRepo.query!(
        """
        SELECT toDate(start) AS day, traffic, count() AS sessions, sum(pageviews) AS pageviews
        FROM sessions_v2 FINAL
        WHERE site_id = {site:UInt64} AND start >= {since:Date} AND start < {until:Date}
        GROUP BY day, traffic
        """,
        params
      )

    %{rows: reasons} =
      ClickhouseRepo.query!(
        """
        SELECT reason, traffic, count() AS sessions
        FROM sessions_v2 FINAL
        ARRAY JOIN traffic_reasons AS reason
        WHERE site_id = {site:UInt64} AND start >= {since:Date} AND start < {until:Date}
        GROUP BY reason, traffic
        """,
        params
      )

    by_day =
      Enum.reduce(daily, %{}, fn [day, traffic, sessions, pageviews], acc ->
        class = @classes[traffic]

        Map.update(
          acc,
          day,
          %{class => %{sessions: sessions, pageviews: pageviews}},
          &Map.put(&1, class, %{sessions: sessions, pageviews: pageviews})
        )
      end)

    totals =
      Enum.reduce(daily, %{}, fn [_, traffic, sessions, pageviews], acc ->
        Map.update(
          acc,
          @classes[traffic],
          %{sessions: sessions, pageviews: pageviews},
          &%{sessions: &1.sessions + sessions, pageviews: &1.pageviews + pageviews}
        )
      end)

    reasons =
      reasons
      |> Enum.group_by(&hd/1)
      |> Enum.map(fn {reason, rows} ->
        by_class = Map.new(rows, fn [_, traffic, n] -> {@classes[traffic], n} end)

        %{
          reason: reason,
          sessions: Enum.reduce(rows, 0, &(List.last(&1) + &2)),
          by_class: by_class
        }
      end)
      |> Enum.sort_by(& &1.sessions, :desc)

    %{since: since, until: today, daily: by_day, totals: totals, reasons: reasons}
  end

  @doc "Everything the admin API and MCP server return for a site: classes, reasons, edge, alerts."
  def api_report(site, days, today \\ Date.utc_today()) do
    quality = report(site.id, days, today)
    edge = Plausible.EdgeRequests.report(site.id, days, today)

    %{
      site_id: site.domain,
      days: days,
      since: quality.since,
      until: quality.until,
      timezone: "UTC",
      classes: quality.totals,
      daily:
        for day <- Date.range(quality.since, quality.until) do
          q = Map.get(quality.daily, day, %{})

          %{
            date: day,
            sessions: Map.new(~w(human suspicious bot), &{&1, get_in(q, [&1, :sessions]) || 0}),
            pageviews: Enum.reduce(Map.values(q), 0, &(&1.pageviews + &2)),
            edge_requests: Map.get(edge.daily, day, %{})
          }
        end,
      reasons:
        Enum.map(quality.reasons, fn r ->
          {description, effect} = reason_info(r.reason)
          Map.merge(r, %{description: description, effect: effect})
        end),
      edge: %{
        enabled: Plausible.EdgeRequests.enabled?(),
        synced_at: edge.synced_at,
        total: edge.total,
        categories: edge.categories,
        agents: Enum.take(edge.agents, 50)
      },
      alerts_day: Date.add(today, -1),
      alerts: Plausible.TrafficAlerts.evaluate(site.id, Date.add(today, -1))
    }
  end
end
