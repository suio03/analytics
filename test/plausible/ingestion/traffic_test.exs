defmodule Plausible.Ingestion.TrafficTest do
  use ExUnit.Case, async: true

  alias Plausible.Ingestion.{DatacenterIP, Request, Traffic}

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

  @old_chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
  @old_chrome_mobile "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Mobile Safari/537.36"
  @nov_2026 ~N[2026-11-09 03:00:00]

  defp classify(attrs) do
    defaults = %{
      event_name: "pageview",
      automation: 0,
      referrer: "https://www.google.com/",
      timestamp: ~N[2024-11-20 00:00:00]
    }

    request = struct!(Request, Map.merge(defaults, attrs))
    ua = if request.user_agent, do: UAInspector.parse(request.user_agent)
    Traffic.classify(request, ua)
  end

  describe "classify/2" do
    test "regular browser is human" do
      assert {0, []} = classify(%{user_agent: @chrome, remote_ip: "81.2.69.142"})
    end

    test "known crawler is a bot" do
      assert {2, ["bot_ua"]} =
               classify(%{user_agent: "Googlebot/2.1 (+http://www.google.com/bot.html)"})
    end

    test "automation tools are bots" do
      for ua <- ["Lightpanda/1.0", "python-requests/2.31", "curl/8.4.0", "Go-http-client/1.1"] do
        assert {2, ["headless_ua" | _]} = classify(%{user_agent: ua}), ua
      end
    end

    test "an unidentifiable browser alone is suspicious" do
      assert {1, ["unknown_ua", "no_device"]} = classify(%{user_agent: "Foo/1.0"})
    end

    test "a datacenter IP alone does not change the class" do
      assert {0, ["datacenter_ip"]} = classify(%{user_agent: @chrome, remote_ip: "3.0.0.1"})
    end

    test "a single tracker headless hint stays human, two are suspicious" do
      assert {0, ["zero_window"]} = classify(%{user_agent: @chrome, automation: 4})

      assert {1, ["zero_window", "no_languages"]} =
               classify(%{user_agent: @chrome, automation: 12})
    end

    test "webdriver reported by the tracker is a bot" do
      assert {2, ["webdriver"]} = classify(%{user_agent: @chrome, automation: 1})
    end

    test "non-pageview events without user agent are human" do
      assert {0, []} = classify(%{event_name: "signup", user_agent: nil})
    end

    test "pageviews without user agent are suspicious" do
      assert {1, ["unknown_ua", "no_device"]} = classify(%{user_agent: nil})
    end

    test "estimates the current Chrome major from the release cadence" do
      assert Traffic.current_chrome_major(~D[2024-11-12]) == 131
      assert Traffic.current_chrome_major(~D[2026-11-09]) == 156
      assert Traffic.outdated_chrome_major(~D[2026-11-09]) == 150
    end

    test "an outdated desktop Chrome landing without referrer is suspicious" do
      assert {1, ["outdated_browser", "no_referrer"]} =
               classify(%{user_agent: @old_chrome, referrer: nil, timestamp: @nov_2026})
    end

    test "an outdated desktop Chrome with a referrer or campaign stays human" do
      assert {0, ["outdated_browser"]} =
               classify(%{user_agent: @old_chrome, timestamp: @nov_2026})

      assert {0, ["outdated_browser"]} =
               classify(%{
                 user_agent: @old_chrome,
                 referrer: nil,
                 query_params: %{"utm_source" => "newsletter"},
                 timestamp: @nov_2026
               })
    end

    test "recent desktop Chrome and mobile Chrome are not outdated" do
      assert {0, []} =
               classify(%{
                 user_agent: @old_chrome,
                 referrer: nil,
                 timestamp: ~N[2026-05-20 00:00:00]
               })

      assert {0, []} =
               classify(%{user_agent: @old_chrome_mobile, referrer: nil, timestamp: @nov_2026})
    end
  end

  describe "DatacenterIP" do
    test "matches cloud ranges for IPv4, IPv6 and mapped IPv4" do
      assert DatacenterIP.datacenter?("3.0.0.1")
      assert DatacenterIP.datacenter?("::ffff:3.0.0.1")
      refute DatacenterIP.datacenter?("81.2.69.142")
      refute DatacenterIP.datacenter?("127.0.0.1")
      refute DatacenterIP.datacenter?("not an ip")
      refute DatacenterIP.datacenter?(nil)
    end

    test "loads and merges ranges from a file" do
      path = Path.join(System.tmp_dir!(), "dc_ranges_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "10.0.0.0/25\n10.0.0.128/25\n2001:db8::/32\ngarbage\n")

      on_exit(fn -> File.rm(path) end)

      ranges = DatacenterIP.load(path)
      assert tuple_size(ranges.v4) == 1
      assert DatacenterIP.datacenter?("10.0.0.200", ranges)
      refute DatacenterIP.datacenter?("10.0.1.0", ranges)
      assert DatacenterIP.datacenter?("2001:db8::1", ranges)
      refute DatacenterIP.datacenter?("2001:db9::1", ranges)
    end
  end
end
