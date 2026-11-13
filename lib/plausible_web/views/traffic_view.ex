defmodule PlausibleWeb.TrafficView do
  use PlausibleWeb, :view

  alias Plausible.EdgeRequests.Agents

  defdelegate frame(assigns), to: PlausibleWeb.Components.SiteFrame
  defdelegate stat(assigns), to: PlausibleWeb.EconomicsView

  defdelegate csrf, to: PlausibleWeb.Components.SiteFrame

  def path(site, suffix \\ ""), do: "/#{URI.encode_www_form(site.domain)}/traffic#{suffix}"

  def num(nil), do: "—"
  def num(0), do: "0"

  def num(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def pct(_, 0), do: "—"
  def pct(_, nil), do: "—"
  def pct(n, total), do: "#{round(n * 100 / total)}%"

  def sessions(map, class), do: get_in(map, [class, :sessions]) || 0
  def pageviews(map, class), do: get_in(map, [class, :pageviews]) || 0

  def all_pageviews(map),
    do: Enum.reduce(~w(human suspicious bot), 0, &(pageviews(map, &1) + &2))

  def all_sessions(map),
    do: Enum.reduce(~w(human suspicious bot), 0, &(sessions(map, &1) + &2))

  def days_desc(since, until), do: Date.range(until, since, -1)

  def category_label(category), do: Agents.label(category)
  def categories, do: Agents.categories()

  def ai(categories),
    do: Map.get(categories, "ai_training", 0) + Map.get(categories, "ai_assistant", 0)

  def bots(categories),
    do:
      categories
      |> Map.drop(["browser", "fake_browser"])
      |> Map.values()
      |> Enum.sum()

  def synced(nil), do: "never"
  def synced(dt), do: Calendar.strftime(dt, "%b %-d · %H:%M UTC")

  def alert_class(:critical),
    do:
      "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-900/30 dark:text-red-200"

  def alert_class(:warning),
    do:
      "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-900/30 dark:text-amber-200"

  def alert_class(:info),
    do:
      "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-900 dark:bg-sky-900/30 dark:text-sky-200"

  def reason_description(reason), do: elem(Plausible.TrafficQuality.reason_info(reason), 0)
  def reason_effect(reason), do: elem(Plausible.TrafficQuality.reason_info(reason), 1)

  def effect_label(:bot), do: "Bot alone"
  def effect_label(:strong), do: "Suspicious alone"
  def effect_label(:weak), do: "Weak (2 needed)"
  def effect_label(:evidence), do: "Evidence only"

  def effect_class(:bot), do: "bg-red-50 text-red-700 dark:bg-red-900/30 dark:text-red-300"

  def effect_class(:strong),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300"

  def effect_class(:weak), do: "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
  def effect_class(:evidence), do: "bg-sky-50 text-sky-700 dark:bg-sky-900/30 dark:text-sky-300"

  @report_labels ["Summary", "What's inflating the numbers", "Crawlers", "What to do"]

  @doc "Splits a written report into `{:heading | :bullet | :text, text}` lines."
  def report_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "- ") ->
          {:bullet, String.trim_leading(line, "- ")}

        String.trim_trailing(line, ":") in @report_labels ->
          {:heading, String.trim_trailing(line, ":")}

        String.length(line) < 40 and not String.ends_with?(line, ".") ->
          {:heading, line}

        true ->
          {:text, line}
      end
    end)
  end

  def line_class({:heading, _}), do: "pt-3 first:pt-0 font-semibold"

  def line_class({:bullet, _}),
    do: "pl-4 -indent-3 before:content-['•'] before:mr-2 before:text-gray-400"

  def line_class(_), do: ""

  def line_text({_, text}), do: text
end
