defmodule Plausible.Ingestion.EventTest do
  use Plausible.DataCase, async: true

  import Phoenix.ConnTest

  alias Plausible.Ingestion.Request
  alias Plausible.Ingestion.Event

  test "processes a request into an event" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://#{site.domain}"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [_], dropped: []}} = Event.build_and_buffer(request)
  end

  @regressive_user_agents [
    ~s|Mozilla/5.0 (Macintosh; Intel Mac OS X 13_2_1) AppleWebKit/537.3666 (KHTML, like Gecko) Chrome/110.0.0.0.0 Safari/537.3666|,
    ~s|Mozilla/5.0 (Linux; arm_64; Android 10; Mi Note 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.5765.05 Mobile Safari/537.36|
  ]

  for {user_agent, idx} <- Enum.with_index(@regressive_user_agents) do
    test "processes user agents known to cause problems parsing in the past (case #{idx})" do
      site = insert(:site)

      payload = %{
        name: "pageview",
        url: "http://#{site.domain}"
      }

      conn =
        build_conn(:post, "/api/events", payload)
        |> Plug.Conn.put_req_header("user-agent", unquote(user_agent))

      assert {:ok, request} = Request.build(conn)

      assert {:ok, %{buffered: [_], dropped: []}} = Event.build_and_buffer(request)
    end
  end

  test "drops verification agent" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://#{site.domain}"
    }

    conn =
      build_conn(:post, "/api/events", payload)
      |> Plug.Conn.put_req_header("user-agent", Plausible.Verification.user_agent())

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :verification_agent
  end

  test "drops a request when site does not exists" do
    payload = %{
      name: "pageview",
      url: "http://dummy.site"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :not_found
  end

  test "drops a request when referrer is spam" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      referrer: "https://www.1-best-seo.com",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :spam_referrer
  end

  test "drops a request when referrer is spam for multiple domains" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      referrer: "https://www.1-best-seo.com",
      d: "#{site.domain},#{site.domain}"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{dropped: [dropped, dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :spam_referrer
  end

  test "selectively drops an event for multiple domains" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      d: "#{site.domain},thisdoesnotexist.com"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [_], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :not_found
  end

  test "selectively drops an event when rate-limited" do
    site = insert(:site, ingest_rate_limit_threshold: 1)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      d: "#{site.domain}"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [_], dropped: []}} = Event.build_and_buffer(request)
    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :throttle
  end

  test "drops a request when header x-plausible-ip-type is dc_ip" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)
    conn = Plug.Conn.put_req_header(conn, "x-plausible-ip-type", "dc_ip")
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :dc_ip
  end

  test "drops a request when ip is on blocklist" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)
    conn = %{conn | remote_ip: {127, 7, 7, 7}}

    {:ok, _} = Plausible.Shields.add_ip_rule(site, %{"inet" => "127.7.7.7"})

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :site_ip_blocklist
  end

  test "drops a request when country is on blocklist" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)
    conn = %{conn | remote_ip: {216, 160, 83, 56}}

    %{country_code: cc} = Plausible.Ingestion.Geolocation.lookup("216.160.83.56")
    {:ok, _} = Plausible.Shields.add_country_rule(site, %{"country_code" => cc})

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :site_country_blocklist
  end

  test "drops a request when page is on blocklist" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site/blocked/page",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)

    {:ok, _} = Plausible.Shields.add_page_rule(site, %{"page_path" => "/blocked/**"})

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :site_page_blocklist
  end

  test "drops a request when hostname allowlist is defined and hostname is not on the list" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)

    {:ok, _} = Plausible.Shields.add_hostname_rule(site, %{"hostname" => "subdomain.dummy.site"})

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :site_hostname_allowlist
  end

  test "passes a request when hostname allowlist is defined and hostname is on the list" do
    site = insert(:site)

    payload = %{
      name: "pageview",
      url: "http://subdomain.dummy.site",
      domain: site.domain
    }

    conn = build_conn(:post, "/api/events", payload)

    {:ok, _} = Plausible.Shields.add_hostname_rule(site, %{"hostname" => "subdomain.dummy.site"})

    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [_], dropped: []}} = Event.build_and_buffer(request)
  end

  test "drops events for site with accept_trafic_until in the past" do
    yesterday = Date.add(Date.utc_today(), -1)

    site =
      insert(:site,
        ingest_rate_limit_threshold: 1,
        members: [build(:user, accept_traffic_until: yesterday)]
      )

    payload = %{
      name: "pageview",
      url: "http://dummy.site",
      d: "#{site.domain}"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :payment_required
  end

  @tag :slow
  test "drops events on session lock timeout" do
    site = insert(:site)

    very_slow_buffer = fn sessions ->
      Process.sleep(1000)
      Plausible.Session.WriteBuffer.insert(sessions)
    end

    first_conn =
      build_conn(:post, "/api/events", %{
        name: "pageview",
        url: "http://dummy.site",
        d: "#{site.domain}"
      })

    assert {:ok, first_request} = Request.build(first_conn)

    second_conn =
      build_conn(:post, "/api/events", %{
        name: "page_scrolled",
        url: "http://dummy.site",
        d: "#{site.domain}"
      })

    assert {:ok, second_request} = Request.build(second_conn)

    Task.start(fn ->
      assert {:ok, %{buffered: [_event], dropped: []}} =
               Event.build_and_buffer(first_request,
                 session_write_buffer_insert: very_slow_buffer
               )
    end)

    Process.sleep(100)

    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(second_request)
    assert dropped.drop_reason == :lock_timeout
  end

  test "drops pageleave event when no session found from cache" do
    site = insert(:site)

    payload = %{
      name: "pageleave",
      url: "https://#{site.domain}/123",
      d: "#{site.domain}"
    }

    conn = build_conn(:post, "/api/events", payload)

    assert {:ok, request} = Request.build(conn)
    assert {:ok, %{buffered: [], dropped: [dropped]}} = Event.build_and_buffer(request)
    assert dropped.drop_reason == :no_session_for_pageleave
  end

  @tag :ee_only
  test "saves revenue amount" do
    site = insert(:site)
    _goal = insert(:goal, event_name: "checkout", currency: "USD", site: site)

    payload = %{
      name: "checkout",
      url: "http://#{site.domain}",
      revenue: %{amount: 10.2, currency: "USD"}
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [event], dropped: []}} = Event.build_and_buffer(request)
    assert Decimal.eq?(event.clickhouse_event.revenue_source_amount, Decimal.new("10.2"))
  end

  test "does not save revenue amount when there is no revenue goal" do
    site = insert(:site)

    payload = %{
      name: "checkout",
      url: "http://#{site.domain}",
      revenue: %{amount: 10.2, currency: "USD"}
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [event], dropped: []}} = Event.build_and_buffer(request)
    assert event.clickhouse_event.revenue_source_amount == nil
  end

  test "IPv4 hostname is stored without public suffix processing" do
    _site = insert(:site, domain: "192.168.0.1")

    payload = %{
      name: "checkout",
      url: "http://192.168.0.1"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [event]}} = Event.build_and_buffer(request)
    assert event.clickhouse_event.hostname == "192.168.0.1"
  end

  test "Hostname is stored with public suffix processing" do
    _site = insert(:site, domain: "foo.netlify.app")

    payload = %{
      name: "checkout",
      url: "http://foo.netlify.app"
    }

    conn = build_conn(:post, "/api/events", payload)
    assert {:ok, request} = Request.build(conn)

    assert {:ok, %{buffered: [event]}} = Event.build_and_buffer(request)
    assert event.clickhouse_event.hostname == "foo.netlify.app"
  end

  defp user_id_for(site, headers, extra, context \\ []) do
    payload = Map.merge(%{name: "pageview", url: "http://#{site.domain}/"}, extra)

    conn =
      Enum.reduce(headers, build_conn(:post, "/api/events", payload), fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    {:ok, request} = Request.build(conn)
    {:ok, %{buffered: [event], dropped: []}} = Event.build_and_buffer(request, context)
    event.clickhouse_event.user_id
  end

  describe "cookie mode visitor id" do
    @chrome ~s|Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36|
    @safari ~s|Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1|

    test "the same v is one visitor whatever the IP and user agent" do
      site = insert(:site)

      desk = [{"user-agent", @chrome}, {"x-forwarded-for", "1.1.1.1"}]
      phone = [{"user-agent", @safari}, {"x-forwarded-for", "2.2.2.2"}]

      a = user_id_for(site, desk, %{v: "visitorAAAA1111"})
      b = user_id_for(site, phone, %{v: "visitorAAAA1111"})
      c = user_id_for(site, desk, %{v: "visitorBBBB2222"})

      assert a == b
      assert a != c
    end

    test "the visitor id from v does not change when the daily salt rotates" do
      site = insert(:site)
      headers = [{"user-agent", @chrome}, {"x-forwarded-for", "1.1.1.1"}]
      day1 = [salts: %{current: :crypto.strong_rand_bytes(16), previous: nil}]
      day2 = [salts: %{current: :crypto.strong_rand_bytes(16), previous: nil}]

      assert user_id_for(site, headers, %{v: "visitorAAAA1111"}, day1) ==
               user_id_for(site, headers, %{v: "visitorAAAA1111"}, day2)

      assert user_id_for(site, headers, %{}, day1) != user_id_for(site, headers, %{}, day2)
    end
  end
end
