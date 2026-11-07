defmodule Plausible.Ingestion.Traffic do
  @moduledoc """
  Classifies incoming traffic as human, suspicious or bot.

  The class is decided when a session starts and is stored on the session and
  on every event of that session (`traffic` column):

    * `0` - human
    * `1` - suspicious: at least two weak signals, e.g. an unidentifiable
      browser coming from a cloud provider network
    * `2` - bot: one strong signal, e.g. a known crawler user agent, a
      headless browser or a tracker reported `navigator.webdriver`

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
    signals =
      user_agent_signals(request, user_agent) ++
        automation_signals(request.automation) ++
        ip_signals(request.remote_ip)

    reasons = Enum.map(signals, &elem(&1, 0))

    class =
      cond do
        Enum.any?(signals, &(elem(&1, 1) == :bot)) -> @bot
        Enum.count(signals, &(elem(&1, 1) == :suspicious)) >= @suspicious_threshold -> @suspicious
        true -> @human
      end

    {class, reasons}
  end

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
        unknown_ua(user_agent) ++ no_device(user_agent)
    end
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

  defp ip_signals(ip) do
    if DatacenterIP.datacenter?(ip), do: [{"datacenter_ip", :suspicious}], else: []
  end
end
