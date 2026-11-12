defmodule Plausible.TrafficAlerts do
  @moduledoc """
  Rule alerts and baseline anomalies for a site's last complete UTC day
  (docs/traffic-quality.md). Computed on demand from stored data, nothing is
  kept: the Traffic quality page and the admin API show the same list.

  Rules look at the shape of one day's traffic (non-human share, cloud
  networks, forged search referrers, visitor farms, crawlers at the edge).
  Anomalies compare the day with the 14 days before it (human sessions,
  non-human sessions, sessions by source, AI crawler requests).
  """

  alias Plausible.{ClickhouseRepo, EdgeRequests, TrafficQuality}

  @baseline_days 14

  @type alert :: %{
          level: :critical | :warning | :info,
          kind: String.t(),
          title: String.t(),
          detail: String.t()
        }

  @doc "Alerts for `day` (default: yesterday, UTC), most severe first."
  @spec evaluate(pos_integer(), Date.t()) :: [alert()]
  def evaluate(site_id, day \\ Date.add(Date.utc_today(), -1)) do
    quality = TrafficQuality.report(site_id, @baseline_days + 1, day)
    reasons = TrafficQuality.report(site_id, 1, day).reasons
    edge = EdgeRequests.report(site_id, @baseline_days + 1, day)

    (rules(quality, reasons, day) ++
       anomalies(quality, day) ++
       source_surges(site_id, day) ++
       edge_alerts(edge, day))
    |> Enum.sort_by(&level_rank(&1.level))
  end

  defp level_rank(:critical), do: 0
  defp level_rank(:warning), do: 1
  defp level_rank(:info), do: 2

  ## Rules

  defp rules(quality, reasons, day) do
    today = Map.get(quality.daily, day, %{})
    human = sessions(today, "human")
    nonhuman = sessions(today, "suspicious") + sessions(today, "bot")
    total = human + nonhuman
    reason = fn name -> Enum.find_value(reasons, 0, &(&1.reason == name && &1.sessions)) end

    [
      share_alert(nonhuman, total, 50, [{0.5, :critical}, {0.3, :warning}], %{
        kind: "nonhuman_share",
        title: "Non-human traffic",
        detail: "of sessions were suspicious or bots"
      }),
      share_alert(reason.("datacenter_ip"), total, 50, [{0.25, :warning}], %{
        kind: "datacenter_share",
        title: "Cloud network traffic",
        detail: "of sessions came from cloud provider networks"
      }),
      count_share_alert(reason.("forged_search_referrer"), total, 10, 0.05, %{
        kind: "forged_search",
        title: "Forged search referrers",
        detail: "sessions claimed a search click that no search engine sends"
      }),
      count_share_alert(reason.("oneshot_farm"), total, 1, 0, %{
        kind: "visitor_farm",
        title: "One-shot visitor farm",
        detail: "one-page sessions from farm networks were marked suspicious",
        level: :info
      })
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp share_alert(count, total, min_total, thresholds, alert) when total >= min_total do
    share = count / total

    case Enum.find(thresholds, fn {threshold, _} -> share >= threshold end) do
      {_, level} ->
        Map.merge(alert, %{
          level: level,
          detail: "#{round(share * 100)}% #{alert.detail} (#{count} of #{total})."
        })

      nil ->
        nil
    end
  end

  defp share_alert(_, _, _, _, _), do: nil

  defp count_share_alert(count, total, min_count, min_share, alert) do
    if count >= min_count and total > 0 and count / total >= min_share do
      alert
      |> Map.put_new(:level, :warning)
      |> Map.put(:detail, "#{count} #{alert.detail} (#{round(count * 100 / total)}%).")
    end
  end

  ## Baseline anomalies

  defp anomalies(quality, day) do
    series = fn fun ->
      for d <- Date.range(Date.add(day, -@baseline_days), Date.add(day, -1)),
          do: fun.(Map.get(quality.daily, d, %{}))
    end

    today = Map.get(quality.daily, day, %{})
    human = &sessions(&1, "human")
    nonhuman = &(sessions(&1, "suspicious") + sessions(&1, "bot"))

    [
      drop_or_spike(human.(today), series.(human), %{
        kind: "human_sessions",
        title: "Human sessions"
      }),
      surge(nonhuman.(today), series.(nonhuman), 50, 3, %{
        kind: "nonhuman_surge",
        title: "Bot surge",
        detail: "suspicious and bot sessions"
      })
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def drop_or_spike(value, baseline, alert) do
    {mean, sd} = mean_sd(baseline)

    cond do
      mean < 20 ->
        nil

      value < mean - 3 * sd and value < mean * 0.6 ->
        Map.merge(alert, %{
          level: :warning,
          title: alert.title <> " dropped",
          detail:
            "#{value} against a 14-day average of #{round(mean)} (#{change(value, mean)}). Check the tracker is still installed."
        })

      value > mean + 3 * sd and value > mean * 2 ->
        Map.merge(alert, %{
          level: :info,
          title: alert.title <> " spiked",
          detail: "#{value} against a 14-day average of #{round(mean)} (#{change(value, mean)})."
        })

      true ->
        nil
    end
  end

  defp surge(value, baseline, min_value, factor, alert) do
    {mean, sd} = mean_sd(baseline)

    if value >= min_value and value >= factor * max(mean, 1) and value > mean + 3 * sd do
      Map.merge(alert, %{
        level: :warning,
        detail:
          "#{value} #{alert.detail} against a 14-day average of #{round(mean)} (#{change(value, mean)})."
      })
    end
  end

  defp source_surges(site_id, day) do
    %{rows: rows} =
      ClickhouseRepo.query!(
        """
        SELECT source,
               countIf(toDate(start) = {day:Date}) AS today,
               countIf(toDate(start) < {day:Date}) / {days:UInt32} AS mean
        FROM (
          SELECT if(referrer_source = '', 'Direct / None', referrer_source) AS source, start
          FROM sessions_v2 FINAL
          WHERE site_id = {site:UInt64} AND traffic = 0
            AND start >= {since:Date} AND start < {until:Date}
        )
        GROUP BY source
        HAVING today >= 30 AND today >= 5 * greatest(mean, 1)
        ORDER BY today DESC
        LIMIT 5
        """,
        %{
          "site" => site_id,
          "day" => day,
          "days" => @baseline_days,
          "since" => Date.add(day, -@baseline_days),
          "until" => Date.add(day, 1)
        }
      )

    for [source, today, mean] <- rows do
      %{
        level: :info,
        kind: "source_surge",
        title: "Surge from #{source}",
        detail:
          if(mean < 1,
            do: "#{today} human sessions from a source that sent almost none before.",
            else: "#{today} human sessions against a 14-day average of #{round(mean)}."
          )
      }
    end
  end

  ## Edge

  defp edge_alerts(%{total: 0}, _day), do: []

  defp edge_alerts(edge, day) do
    today = Map.get(edge.daily, day, %{})
    fake = Map.get(today, "fake_browser", 0)
    browsers = Map.get(today, "browser", 0)
    ai = &(Map.get(&1, "ai_training", 0) + Map.get(&1, "ai_assistant", 0))

    baseline =
      for d <- Date.range(Date.add(day, -@baseline_days), Date.add(day, -1)),
          do: ai.(Map.get(edge.daily, d, %{}))

    [
      if fake >= 100 and fake > browsers do
        %{
          level: :info,
          kind: "fake_browsers",
          title: "Fake browsers outnumber real ones",
          detail:
            "Cloudflare served #{fake} pages to outdated or malformed browser user agents and #{browsers} to current browsers."
        }
      end,
      surge(ai.(today), baseline, 100, 3, %{
        kind: "ai_crawler_surge",
        title: "AI crawler surge",
        detail: "page requests from AI crawlers"
      })
    ]
    |> Enum.reject(&is_nil/1)
  end

  ## Helpers

  defp sessions(map, class), do: get_in(map, [class, :sessions]) || 0

  defp mean_sd([]), do: {0, 0}

  defp mean_sd(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    variance = Enum.reduce(values, 0, &(&2 + (&1 - mean) ** 2)) / n
    {mean, :math.sqrt(variance)}
  end

  defp change(_value, mean) when mean == 0, do: "new"

  defp change(value, mean) do
    pct = round((value - mean) * 100 / mean)
    if pct >= 0, do: "+#{pct}%", else: "#{pct}%"
  end
end
