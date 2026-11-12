defmodule Plausible.TrafficReport do
  @moduledoc """
  A written summary of a site's traffic quality (docs/traffic-quality.md).

  Every number comes from `Plausible.TrafficQuality.api_report/3` plus a few
  shares computed here. The model only gets those facts and is told to quote
  them, never to work out new figures. Numbers in the answer that can't be
  found in the facts are returned as `ungrounded` so the page can flag them.

  Calls the Claude Messages API over HTTP (there is no official Elixir SDK).
  Off unless `ANTHROPIC_API_KEY` is set.
  """

  @api "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-5-5"
  @classes ~w(human suspicious bot)

  @system """
  You write short traffic-quality reports for the owner of a website analytics dashboard.

  The user message holds one JSON object of facts about one site over a window of UTC days:
  sessions and pageviews per traffic class (human, suspicious, bot), the classifier reasons
  with what each means and its effect, crawler page requests counted at the Cloudflare edge
  (when enabled), rule-based alerts for yesterday, and precomputed shares under `shares`.

  Rules:
  - Use only the facts given. Quote numbers exactly as they appear in the facts; do not add,
    subtract, average or estimate new figures. If a figure you want isn't there, describe the
    pattern in words instead.
  - When edge data is disabled or empty, say crawler coverage is unknown rather than zero.
  - Plain text, no Markdown headings or tables. Four short sections, each starting with its
    label on its own line: "Summary", "What's inflating the numbers", "Crawlers", "What to do".
    Use "- " bullets inside a section. At most 250 words in total.
  - Write in {language}.
  """

  def enabled?, do: is_binary(api_key()) and api_key() != ""

  @doc """
  Writes the report. Returns `{:ok, %{text, ungrounded, facts}}` or `{:error, message}`.
  """
  def generate(site, days, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    language = Keyword.get(opts, :language, "English")

    if enabled?() do
      facts = facts(site, days, today)
      json = Jason.encode!(facts)

      with {:ok, text} <- complete(json, language) do
        {:ok, %{text: text, ungrounded: ungrounded(text, json), facts: facts}}
      end
    else
      {:error, "Set ANTHROPIC_API_KEY to enable written reports."}
    end
  end

  @doc false
  def facts(site, days, today) do
    report = Plausible.TrafficQuality.api_report(site, days, today)
    Map.put(report, :shares, shares(report))
  end

  defp shares(%{classes: classes, edge: edge}) do
    sessions = Map.new(@classes, &{&1, get_in(classes, [&1, :sessions]) || 0})
    total = Enum.sum(Map.values(sessions))

    session_shares =
      Map.new(sessions, fn {class, n} -> {"#{class}_sessions_pct", pct(n, total)} end)

    browsers = Map.get(edge.categories, "browser", 0)
    tracked = Enum.reduce(@classes, 0, &((get_in(classes, [&1, :pageviews]) || 0) + &2))

    edge_shares =
      if edge.total > 0 do
        %{
          "crawler_requests_pct_of_edge" => pct(edge.total - browsers, edge.total),
          "tracked_pageviews_pct_of_browser_loads" => pct(tracked, browsers)
        }
      else
        %{}
      end

    session_shares
    |> Map.put("all_sessions", total)
    |> Map.merge(edge_shares)
  end

  defp pct(_n, 0), do: nil
  defp pct(n, total), do: Float.round(n * 100 / total, 1)

  defp complete(facts_json, language) do
    body = %{
      model: @model,
      max_tokens: 16_000,
      thinking: %{type: "adaptive"},
      fallbacks: "default",
      system: String.replace(@system, "{language}", language),
      messages: [%{role: "user", content: facts_json}]
    }

    req =
      [
        method: :post,
        url: @api,
        json: body,
        headers: [
          {"x-api-key", api_key()},
          {"anthropic-version", "2026-10-21"},
          {"anthropic-beta", "server-side-fallback-2026-07-01"}
        ],
        receive_timeout: 180_000,
        retry: :transient,
        max_retries: 2
      ] ++ Keyword.take(config(), [:plug])

    case Req.request(req) do
      {:ok, %{status: 200, body: %{"stop_reason" => "refusal"}}} ->
        {:error, "The model declined to write this report."}

      {:ok, %{status: 200, body: %{"content" => content}}} ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])
          |> String.trim()

        if text == "", do: {:error, "The model returned no text."}, else: {:ok, text}

      {:ok, %{status: status}} ->
        {:error, "The Claude API answered HTTP #{status}."}

      {:error, _} ->
        {:error, "Could not reach the Claude API."}
    end
  end

  @number ~r/\d[\d,]*(?:\.\d+)?/

  @doc """
  Numbers in `text` that don't occur in the facts JSON. Small counts (up to
  10) are skipped, they are usually list positions or day counts.
  """
  def ungrounded(text, facts_json) do
    known = facts_json |> numbers() |> MapSet.new()

    text
    |> numbers()
    |> Enum.reject(&(&1 in known or small?(&1)))
    |> Enum.uniq()
  end

  defp numbers(string) do
    @number
    |> Regex.scan(string)
    |> Enum.map(fn [n] -> n |> String.replace(",", "") |> normalize() end)
  end

  # "12.0" and "12" are the same figure
  defp normalize(n) do
    case Float.parse(n) do
      {f, ""} -> if f == Float.round(f), do: Integer.to_string(trunc(f)), else: n
      _ -> n
    end
  end

  defp small?(n) do
    case Float.parse(n) do
      {f, _} -> f <= 10
      :error -> false
    end
  end

  defp api_key, do: config()[:api_key]
  defp config, do: Application.get_env(:plausible, __MODULE__, [])
end
