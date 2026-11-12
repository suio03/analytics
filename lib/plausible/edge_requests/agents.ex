defmodule Plausible.EdgeRequests.Agents do
  @moduledoc """
  Names the crawler behind a user agent and puts it in a category.

  Categories, in display order:

    * `ai_training` - collects pages to train models (GPTBot, ClaudeBot, CCBot...)
    * `ai_assistant` - fetches pages to answer a user or build an AI search index
      (ChatGPT-User, OAI-SearchBot, PerplexityBot...)
    * `search` - search engine crawlers
    * `social` - link previews (facebookexternalhit, Twitterbot, Slackbot...)
    * `seo` - SEO tools (AhrefsBot, SemrushBot...)
    * `monitor` - uptime checks
    * `other_bot` - other self-declared bots, HTTP libraries and empty user agents
    * `fake_browser` - claims to be a browser but isn't a current one: a months
      old desktop Chrome or a user agent no browser sends
    * `browser` - everything else
  """

  alias Plausible.Ingestion.Traffic

  @categories ~w(ai_training ai_assistant search social seo monitor other_bot fake_browser browser)

  @labels %{
    "ai_training" => "AI training",
    "ai_assistant" => "AI assistants & AI search",
    "search" => "Search engines",
    "social" => "Link previews",
    "seo" => "SEO tools",
    "monitor" => "Uptime monitors",
    "other_bot" => "Other bots",
    "fake_browser" => "Fake browsers",
    "browser" => "Browsers"
  }

  # {pattern (case-insensitive substring or regex), agent name, category}. Order matters:
  # the first match wins, so specific names come before their generic siblings.
  @known [
    # AI assistants and AI search (fetch on behalf of a user or for answers)
    {"ChatGPT-User", "ChatGPT-User", "ai_assistant"},
    {"OAI-SearchBot", "OAI-SearchBot", "ai_assistant"},
    {"Perplexity-User", "Perplexity-User", "ai_assistant"},
    {"PerplexityBot", "PerplexityBot", "ai_assistant"},
    {"Claude-User", "Claude-User", "ai_assistant"},
    {"Claude-SearchBot", "Claude-SearchBot", "ai_assistant"},
    {"Claude-Web", "Claude-Web", "ai_assistant"},
    {"DuckAssistBot", "DuckAssistBot", "ai_assistant"},
    {"MistralAI-User", "MistralAI-User", "ai_assistant"},
    {"meta-externalfetcher", "Meta-ExternalFetcher", "ai_assistant"},
    {"YouBot", "YouBot", "ai_assistant"},
    {"Gemini-Deep-Research", "Gemini-Deep-Research", "ai_assistant"},
    {"Google-NotebookLM", "Google-NotebookLM", "ai_assistant"},
    {"PhindBot", "PhindBot", "ai_assistant"},
    {"kagi-fetcher", "Kagi", "ai_assistant"},
    {"ExaSearchBot", "ExaSearchBot", "ai_assistant"},
    {"meta-webindexer", "Meta-WebIndexer", "ai_assistant"},
    # AI training
    {"GPTBot", "GPTBot", "ai_training"},
    {"ClaudeBot", "ClaudeBot", "ai_training"},
    {"anthropic-ai", "anthropic-ai", "ai_training"},
    {"CCBot", "CCBot", "ai_training"},
    {"Bytespider", "Bytespider", "ai_training"},
    {"meta-externalagent", "Meta-ExternalAgent", "ai_training"},
    {"Amazonbot", "Amazonbot", "ai_training"},
    {"Applebot-Extended", "Applebot-Extended", "ai_training"},
    {"cohere-training-data-crawler", "Cohere", "ai_training"},
    {"cohere-ai", "Cohere", "ai_training"},
    {"Diffbot", "Diffbot", "ai_training"},
    {"AI2Bot", "AI2Bot", "ai_training"},
    {"img2dataset", "img2dataset", "ai_training"},
    {"omgili", "Omgili", "ai_training"},
    {"Timpibot", "Timpibot", "ai_training"},
    {"ImagesiftBot", "ImagesiftBot", "ai_training"},
    {"PanguBot", "PanguBot", "ai_training"},
    {"TikTokSpider", "TikTokSpider", "ai_training"},
    {"DeepSeekBot", "DeepSeekBot", "ai_training"},
    # Search engines
    {"Google-InspectionTool", "Google-InspectionTool", "search"},
    {"Storebot-Google", "Storebot-Google", "search"},
    {"AdsBot-Google", "AdsBot-Google", "search"},
    {"Mediapartners-Google", "Mediapartners-Google", "search"},
    {"GoogleOther", "GoogleOther", "search"},
    {"Googlebot", "Googlebot", "search"},
    {"bingbot", "Bingbot", "search"},
    {"BingPreview", "Bingbot", "search"},
    {"YandexBot", "YandexBot", "search"},
    {"YandexMobileBot", "YandexBot", "search"},
    {"Baiduspider", "Baiduspider", "search"},
    {"DuckDuckBot", "DuckDuckBot", "search"},
    {"Applebot", "Applebot", "search"},
    {"Sogou", "Sogou", "search"},
    {"Yeti", "Naver", "search"},
    {"SeznamBot", "SeznamBot", "search"},
    {"PetalBot", "PetalBot", "search"},
    {"Qwantbot", "Qwantbot", "search"},
    {"coccocbot", "Coc Coc", "search"},
    {"MojeekBot", "MojeekBot", "search"},
    {"360Spider", "360Spider", "search"},
    # Link previews
    {"facebookexternalhit", "facebookexternalhit", "social"},
    {"facebookcatalog", "facebookcatalog", "social"},
    {"Twitterbot", "Twitterbot", "social"},
    {"LinkedInBot", "LinkedInBot", "social"},
    {"Slackbot", "Slackbot", "social"},
    {"Slack-ImgProxy", "Slackbot", "social"},
    {"Discordbot", "Discordbot", "social"},
    {"TelegramBot", "TelegramBot", "social"},
    {"WhatsApp", "WhatsApp", "social"},
    {"Pinterestbot", "Pinterestbot", "social"},
    {"redditbot", "redditbot", "social"},
    {"Embedly", "Embedly", "social"},
    {"Iframely", "Iframely", "social"},
    {"SkypeUriPreview", "Skype", "social"},
    {"vkShare", "VK", "social"},
    {"Snap URL Preview", "Snapchat", "social"},
    {"Cardyb", "Bluesky", "social"},
    {"Mastodon", "Mastodon", "social"},
    {"Bytedance", "ByteDance preview", "social"},
    {"GeedoShopProductFinder", "Geedo", "other_bot"},
    {"Chrome Privacy Preserving Prefetch Proxy", "Chrome prefetch proxy", "other_bot"},
    # SEO tools
    {"AhrefsSiteAudit", "AhrefsSiteAudit", "seo"},
    {"AhrefsBot", "AhrefsBot", "seo"},
    {"SemrushBot", "SemrushBot", "seo"},
    {"SiteAuditBot", "SemrushBot", "seo"},
    {"MJ12bot", "MJ12bot", "seo"},
    {"DotBot", "DotBot", "seo"},
    {"rogerbot", "Moz", "seo"},
    {"Screaming Frog", "Screaming Frog", "seo"},
    {"serpstatbot", "Serpstat", "seo"},
    {"BLEXBot", "BLEXBot", "seo"},
    {"DataForSeoBot", "DataForSeoBot", "seo"},
    {"barkrowler", "Barkrowler", "seo"},
    {"SeekportBot", "SeekportBot", "seo"},
    {"SEOkicks", "SEOkicks", "seo"},
    {"SERankingBacklinksBot", "SE Ranking", "seo"},
    # Uptime monitors
    {"UptimeRobot", "UptimeRobot", "monitor"},
    {"Pingdom", "Pingdom", "monitor"},
    {"StatusCake", "StatusCake", "monitor"},
    {"Better Uptime", "Better Stack", "monitor"},
    {"BetterStack", "Better Stack", "monitor"},
    {"Site24x7", "Site24x7", "monitor"},
    {"Checkly", "Checkly", "monitor"},
    {"Datadog", "Datadog", "monitor"},
    {"cron-job.org", "cron-job.org", "monitor"},
    {"Uptime-Kuma", "Uptime Kuma", "monitor"},
    {"HetrixTools", "HetrixTools", "monitor"}
  ]

  @known_lower Enum.map(@known, fn {pattern, name, category} ->
                 {String.downcase(pattern), name, category}
               end)

  @http_client ~r/^(curl|wget|python-requests|python-urllib|python-httpx|aiohttp|httpx|go-http-client|node-fetch|axios|undici|okhttp|java|apache-httpclient|libwww-perl|ruby|php|guzzlehttp|scrapy|colly|reqwest|dart|postmanruntime|insomnia)\b/i
  @headless ~r/headlesschrome|phantomjs|lightpanda|playwright|puppeteer|selenium/i
  @generic_bot ~r/bot\b|crawl|spider|scrap|slurp|fetch|scan|preview|archiv|checker|validator|monitor/i

  def categories, do: @categories
  def label(category), do: Map.get(@labels, category, category)

  @doc """
  `{agent, category}` for a user agent seen on `date` (used to judge Chrome's
  age). Ordinary browsers are all reported as the agent "Browsers".
  """
  def classify(user_agent, date \\ Date.utc_today())

  def classify(ua, _date) when ua in [nil, ""], do: {"No user agent", "other_bot"}

  def classify(ua, date) when is_binary(ua) do
    lower = String.downcase(ua)

    case Enum.find(@known_lower, fn {pattern, _, _} -> String.contains?(lower, pattern) end) do
      {_, name, category} -> {name, category}
      nil -> classify_unknown(ua, date)
    end
  end

  defp classify_unknown(ua, date) do
    cond do
      Regex.match?(@headless, ua) ->
        {"Headless browsers", "other_bot"}

      Regex.match?(@http_client, ua) ->
        {http_client_name(ua), "other_bot"}

      true ->
        # Shares ingestion's cache: parsing takes ~10 ms and the same user
        # agents come back day after day and across sites.
        case Plausible.Cache.Adapter.get(:user_agents, ua, fn -> UAInspector.parse(ua) end) do
          %UAInspector.Result.Bot{name: name}
          when is_binary(name) and name not in ["", "Generic Bot"] ->
            {name, "other_bot"}

          %UAInspector.Result.Bot{} ->
            {bot_name(ua), "other_bot"}

          %UAInspector.Result{} = result ->
            browser(ua, result, date)
        end
    end
  end

  defp browser(ua, result, date) do
    cond do
      Regex.match?(@generic_bot, ua) and not String.starts_with?(ua, "Mozilla/") ->
        {bot_name(ua), "other_bot"}

      Regex.match?(@generic_bot, ua) and String.contains?(ua, "compatible;") ->
        {bot_name(ua), "other_bot"}

      result.client == :unknown ->
        {"Unidentifiable user agents", "fake_browser"}

      outdated_chrome?(result, date) ->
        {"Outdated desktop Chrome", "fake_browser"}

      true ->
        {"Browsers", "browser"}
    end
  end

  defp outdated_chrome?(
         %UAInspector.Result{
           client: %UAInspector.Result.Client{name: "Chrome", version: version},
           device: %UAInspector.Result.Device{type: "desktop"}
         },
         date
       )
       when is_binary(version) do
    case Integer.parse(version) do
      {major, _} when major > 0 -> major <= Traffic.outdated_chrome_major(date)
      _ -> false
    end
  end

  defp outdated_chrome?(_, _), do: false

  defp http_client_name(ua) do
    [name | _] = String.split(ua, ["/", " "], parts: 2)
    String.slice(name, 0, 40)
  end

  @browser_tokens ~w(mozilla applewebkit chrome safari khtml gecko version mobile firefox edg
                     opr crios fxios samsungbrowser)

  # The first product token that isn't a browser's:
  # "Mozilla/5.0 (compatible; FooBot/2.1; +https://...)" -> "FooBot"
  defp bot_name(ua) do
    ~r/([A-Za-z][\w.-]*)\/\d/
    |> Regex.scan(ua, capture: :all_but_first)
    |> List.flatten()
    |> Enum.find(&(String.downcase(&1) not in @browser_tokens))
    |> case do
      nil -> bot_word(ua)
      name -> String.slice(name, 0, 40)
    end
  end

  defp bot_word(ua) do
    ua
    |> String.split(["(", ")", ";", " ", "+"], trim: true)
    |> Enum.find(fn part ->
      Regex.match?(@generic_bot, part) and not String.contains?(part, [":", "@", "."])
    end)
    |> case do
      nil -> "Other bots"
      part -> part |> String.split("/") |> hd() |> String.slice(0, 40)
    end
  end
end
