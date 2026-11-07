defmodule Plausible.Ingestion.TrafficTest do
  use ExUnit.Case, async: true

  alias Plausible.Ingestion.{DatacenterIP, Request, Traffic}

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

  defp classify(attrs) do
    request = struct!(Request, Map.merge(%{event_name: "pageview", automation: 0}, attrs))
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
