defmodule Plausible.Ingestion.Traffic do
  @moduledoc """
  Classifies incoming traffic as human, suspicious or bot.

  The class is decided when a session starts and is stored on the session and
  on every event of that session (`traffic` column):

    * `0` - human
    * `1` - suspicious: at least two weak signals, e.g. an unidentifiable
      browser coming from a cloud provider network, or a months-old desktop
      Chrome landing without a referrer
    * `2` - bot: one strong signal, e.g. a known crawler user agent, a
      headless browser or a tracker reported `navigator.webdriver`

  Some signals are suspicious on their own (a structurally forged search
  engine referrer), and some are only recorded as evidence in
  `traffic_reasons` without changing the class (missing browser request
  headers) until live traffic shows they don't misfire on real visitors.

  Nothing is dropped any more: dashboards show humans by default and can
  switch to the other classes.
  """

  import Bitwise

  alias Plausible.Ingestion.{DatacenterIP, Request}

  @human 0
  @suspicious 1
  @bot 2

  @suspicious_threshold 2

  # Bitmask sent by the tracker in the `a` field
  @automation_bits [
    {1, "webdriver", :bot},
    {2, "automation_globals", :bot},
    {4, "zero_window", :suspicious},
    {8, "no_languages", :suspicious}
  ]

  # Desktop Chrome auto-updates every four weeks, so real visitors stay within a
  # few releases of the current one. Scraper fleets pin an old Chromium (e.g.
  # Chrome 148-150 from China, Singapore and Hong Kong in November 2026, all
  # direct single-page visits with zero duration). The current major is
  # estimated from Chrome's release cadence instead of a hardcoded number.
  @chrome_anchor_major 131
  @chrome_anchor_date ~D[2024-11-12]
  @chrome_release_days 28
  @chrome_outdated_after 6

  @campaign_params ["utm_source", "ref", "source"]

  @automation_ua ~r/lightpanda|headlesschrome|phantomjs|playwright|puppeteer|selenium|\bcurl\/|\bwget\/|go-http-client|node-fetch|axios\/|python-requests|python-urllib|aiohttp|httpx|scrapy|libwww-perl|java\/\d/i

  def human, do: @human
  def suspicious, do: @suspicious
  def bot, do: @bot

  @doc "Maps a class name to its stored value."
  def class_value(:human), do: @human
  def class_value(:suspicious), do: @suspicious
  def class_value(:bot), do: @bot

  @doc """
  Returns `{class, reasons}` for a request.

  `user_agent` is the parsed UAInspector result (or nil when the request had
  no user agent).
  """
  @spec classify(Request.t(), term()) :: {0 | 1 | 2, [String.t()]}
  def classify(%Request{} = request, user_agent) do
    datacenter? = DatacenterIP.datacenter?(request.remote_ip)

    signals =
      user_agent_signals(request, user_agent) ++
        automation_signals(request.automation) ++
        ip_signals(datacenter?) ++
        search_referrer_signals(request, datacenter?) ++
        header_signals(request, user_agent)

    reasons = Enum.map(signals, &elem(&1, 0))

    weak = Enum.count(signals, &(elem(&1, 1) == :suspicious))

    class =
      cond do
        Enum.any?(signals, &(elem(&1, 1) == :bot)) -> @bot
        Enum.any?(signals, &(elem(&1, 1) == :strong)) -> @suspicious
        weak >= @suspicious_threshold -> @suspicious
        true -> @human
      end

    {class, reasons}
  end

  # A visit claiming to come from a search engine. Real organic clicks come
  # from home and mobile networks, over https, and Google trims its referrer
  # to the bare origin. Scrapers that set `referer: google.com` to pass as
  # organic search break one of these.
  defp search_referrer_signals(%Request{event_name: "pageview", referrer: referrer}, datacenter?)
       when is_binary(referrer) do
    with {:ok, %URI{host: host} = uri} when is_binary(host) <- URI.new(String.trim(referrer)),
         engine when not is_nil(engine) <- search_engine(String.downcase(host)) do
      datacenter = if datacenter?, do: [{"search_ref_datacenter", :suspicious}], else: []
      datacenter ++ forged_search_referrer(engine, uri)
    else
      _ -> []
    end
  end

  defp search_referrer_signals(_request, _datacenter?), do: []

  defp forged_search_referrer(engine, %URI{scheme: scheme, path: path, query: query}) do
    query_leak =
      engine == :google and
        ((is_binary(query) and query != "") or (is_binary(path) and path =~ ~r{^/search\b}))

    if scheme == "http" or query_leak,
      do: [{"forged_search_referrer", :strong}],
      else: []
  end

  @search_engine_hosts ~w(bing.com duckduckgo.com yahoo.com search.yahoo.com baidu.com
                          m.baidu.com ecosia.org search.brave.com qwant.com startpage.com
                          sogou.com so.com)

  @doc false
  def search_engine(host) do
    host = String.replace_prefix(host, "www.", "")

    cond do
      host =~ ~r/^google\.[a-z.]{2,}$/ -> :google
      host =~ ~r/^yandex\.[a-z.]{2,}$/ -> :other
      host in @search_engine_hosts -> :other
      true -> nil
    end
  end

  # Every current browser sends Sec-Fetch-* headers with the tracker's request
  # and Chromium 90+ sends Sec-CH-UA; HTTP clients behind a spoofed user agent
  # usually don't. Recorded as evidence only. Skipped when a site-side proxy
  # relayed the event, as it may not forward these headers.
  defp header_signals(%Request{event_name: "pageview", proxied: false} = request, user_agent) do
    case user_agent do
      %UAInspector.Result{client: %UAInspector.Result.Client{type: "browser"} = client} ->
        no_sec_fetch = if request.browser_headers, do: [], else: [{"no_sec_fetch", :evidence}]

        no_client_hints =
          if not request.client_hints and modern_blink?(client),
            do: [{"no_client_hints", :evidence}],
            else: []

        no_sec_fetch ++ no_client_hints

      _ ->
        []
    end
  end

  defp header_signals(_request, _user_agent), do: []

  defp modern_blink?(%UAInspector.Result.Client{engine: "Blink", engine_version: version})
       when is_binary(version) do
    match?({major, _} when major >= 90, Integer.parse(version))
  end

  defp modern_blink?(_), do: false

  defp user_agent_signals(request, user_agent) do
    ua_string = request.user_agent || ""

    cond do
      match?(%UAInspector.Result.Bot{}, user_agent) ->
        [{"bot_ua", :bot}]

      match?(
        %UAInspector.Result{client: %UAInspector.Result.Client{name: "Headless Chrome"}},
        user_agent
      ) ->
        [{"headless_ua", :bot}]

      Regex.match?(@automation_ua, ua_string) ->
        [{"headless_ua", :bot}]

      # Server side custom events often come without a browser user agent,
      # only pageviews are expected to come from a real browser.
      request.event_name != "pageview" ->
        []

      true ->
        unknown_ua(user_agent) ++
          no_device(user_agent) ++
          outdated_browser(user_agent, request)
    end
  end

  @doc "Estimated current stable major version of Chrome on `date`."
  def current_chrome_major(%Date{} = date) do
    @chrome_anchor_major + div(Date.diff(date, @chrome_anchor_date), @chrome_release_days)
  end

  @doc "Highest desktop Chrome major version considered outdated on `date`."
  def outdated_chrome_major(%Date{} = date) do
    current_chrome_major(date) - @chrome_outdated_after
  end

  defp outdated_browser(
         %UAInspector.Result{
           client: %UAInspector.Result.Client{name: "Chrome", version: version},
           device: %UAInspector.Result.Device{type: "desktop"}
         },
         request
       )
       when is_binary(version) do
    date =
      if request.timestamp,
        do: NaiveDateTime.to_date(request.timestamp),
        else: Date.utc_today()

    case Integer.parse(version) do
      {major, _} when major > 0 ->
        if major <= outdated_chrome_major(date),
          do: [{"outdated_browser", :suspicious} | no_referrer(request)],
          else: []

      _ ->
        []
    end
  end

  defp outdated_browser(_, _), do: []

  # A landing without referrer or campaign parameters ("Direct / None"). Only
  # checked for outdated browsers: on its own it describes most real visitors
  # who type the address, including those behind VPNs on cloud networks.
  defp no_referrer(%Request{referrer: referrer, query_params: params}) do
    has_referrer = is_binary(referrer) and String.trim(referrer) != ""
    has_campaign = is_map(params) and Enum.any?(@campaign_params, &(params[&1] not in [nil, ""]))

    if has_referrer or has_campaign, do: [], else: [{"no_referrer", :suspicious}]
  end

  defp unknown_ua(%UAInspector.Result{client: :unknown, os: :unknown}),
    do: [{"unknown_ua", :suspicious}]

  defp unknown_ua(%UAInspector.Result{}), do: []
  defp unknown_ua(_), do: [{"unknown_ua", :suspicious}]

  defp no_device(%UAInspector.Result{device: %UAInspector.Result.Device{type: type}})
       when is_binary(type),
       do: []

  defp no_device(_), do: [{"no_device", :suspicious}]

  defp automation_signals(bits) when is_integer(bits) and bits > 0 do
    for {bit, reason, kind} <- @automation_bits, (bits &&& bit) != 0, do: {reason, kind}
  end

  defp automation_signals(_), do: []

  defp ip_signals(datacenter?) do
    if datacenter?, do: [{"datacenter_ip", :suspicious}], else: []
  end
end
