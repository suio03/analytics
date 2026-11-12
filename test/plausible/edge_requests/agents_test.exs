defmodule Plausible.EdgeRequests.AgentsTest do
  use ExUnit.Case, async: true

  alias Plausible.EdgeRequests.Agents

  @today ~D[2026-11-12]

  test "names known crawlers by category" do
    for {ua, expected} <- [
          {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)",
           {"GPTBot", "ai_training"}},
          {"Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)",
           {"ClaudeBot", "ai_training"}},
          {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ChatGPT-User/1.0; +https://openai.com/bot)",
           {"ChatGPT-User", "ai_assistant"}},
          {"Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)",
           {"PerplexityBot", "ai_assistant"}},
          {"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
           {"Googlebot", "search"}},
          {"facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
           {"facebookexternalhit", "social"}},
          {"Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
           {"AhrefsBot", "seo"}},
          {"Mozilla/5.0+(compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)",
           {"UptimeRobot", "monitor"}}
        ] do
      assert Agents.classify(ua, @today) == expected, ua
    end
  end

  test "HTTP libraries, headless browsers and empty user agents are other bots" do
    assert Agents.classify("python-requests/2.31.0", @today) == {"python-requests", "other_bot"}
    assert Agents.classify("curl/8.4.0", @today) == {"curl", "other_bot"}

    assert Agents.classify(
             "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36",
             @today
           ) == {"Headless browsers", "other_bot"}

    assert Agents.classify("", @today) == {"No user agent", "other_bot"}
    assert Agents.classify(nil, @today) == {"No user agent", "other_bot"}
  end

  test "unlisted self-declared bots are other bots under their own name" do
    assert {_, "other_bot"} =
             Agents.classify(
               "Mozilla/5.0 (compatible; FooCrawler/2.1; +https://foo.example/bot)",
               @today
             )
  end

  test "current browsers are browsers, outdated desktop Chrome and broken UAs are fake" do
    assert Agents.classify(
             "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36",
             @today
           ) == {"Browsers", "browser"}

    assert Agents.classify(
             "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
             @today
           ) == {"Browsers", "browser"}

    assert Agents.classify(
             "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
             @today
           ) == {"Outdated desktop Chrome", "fake_browser"}

    assert Agents.classify("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", @today) ==
             {"Unidentifiable user agents", "fake_browser"}
  end
end
