defmodule PlausibleWeb.Api.StatsController.TrafficTest do
  use PlausibleWeb.ConnCase

  setup [:create_user, :log_in, :create_new_site]

  defp populate_mixed(site) do
    populate_stats(site, [
      build(:pageview, user_id: 1, timestamp: ~N[2021-01-01 00:00:00], pathname: "/"),
      build(:pageview, user_id: 2, timestamp: ~N[2021-01-01 00:00:00], pathname: "/"),
      build(:pageview, user_id: 2, timestamp: ~N[2021-01-01 00:05:00], pathname: "/about"),
      build(:pageview,
        user_id: 3,
        timestamp: ~N[2021-01-01 00:00:00],
        pathname: "/",
        traffic: 1
      ),
      build(:pageview,
        user_id: 4,
        timestamp: ~N[2021-01-02 00:00:00],
        pathname: "/wp-login.php",
        traffic: 2
      ),
      build(:pageview,
        user_id: 5,
        timestamp: ~N[2021-01-02 00:00:00],
        pathname: "/",
        traffic: 2
      )
    ])
  end

  # Reasons only live on the session, which the test helpers build from the
  # attributes of the event.
  defp with_reasons(event, reasons), do: Map.put(event, :traffic_reasons, reasons)

  @range "period=custom&from=2021-01-01&to=2021-01-02"

  describe "top stats" do
    test "count humans by default and report the other classes", %{conn: conn, site: site} do
      populate_mixed(site)

      res =
        conn
        |> get("/api/stats/#{site.domain}/top-stats?#{@range}")
        |> json_response(200)

      assert %{"name" => "Unique visitors", "value" => 2} = hd(res["top_stats"])
      assert res["traffic"] == %{"human" => 2, "suspicious" => 1, "bot" => 2}
    end

    test "traffic param switches the counted class", %{conn: conn, site: site} do
      populate_mixed(site)

      for {traffic, expected} <- [{"all", 5}, {"bot", 2}, {"suspicious", 1}, {"nonhuman", 3}] do
        res =
          conn
          |> get("/api/stats/#{site.domain}/top-stats?#{@range}&traffic=#{traffic}")
          |> json_response(200)

        assert %{"value" => ^expected} = hd(res["top_stats"]), traffic
      end
    end
  end

  describe "breakdowns" do
    test "pages only list human traffic by default", %{conn: conn, site: site} do
      populate_mixed(site)

      pages =
        conn
        |> get("/api/stats/#{site.domain}/pages?#{@range}")
        |> json_response(200)
        |> Map.get("results")
        |> Enum.map(& &1["name"])

      refute "/wp-login.php" in pages

      bot_pages =
        conn
        |> get("/api/stats/#{site.domain}/pages?#{@range}&traffic=bot")
        |> json_response(200)
        |> Map.get("results")
        |> Enum.map(& &1["name"])

      assert "/wp-login.php" in bot_pages
    end

    test "all traffic breakdowns include human visitors", %{conn: conn, site: site} do
      populate_mixed(site)

      for path <- ["sources", "browsers", "operating-systems", "entry-pages"] do
        results =
          conn
          |> get("/api/stats/#{site.domain}/#{path}?#{@range}&traffic=all")
          |> json_response(200)
          |> Map.get("results")

        assert Enum.sum(Enum.map(results, & &1["human_visitors"])) == 2, path
      end

      pages =
        conn
        |> get("/api/stats/#{site.domain}/pages?#{@range}&traffic=all")
        |> json_response(200)
        |> Map.get("results")
        |> Map.new(&{&1["name"], {&1["visitors"], &1["human_visitors"]}})

      assert pages == %{"/" => {4, 2}, "/about" => {1, 1}, "/wp-login.php" => {1, 0}}

      [row | _] =
        conn
        |> get("/api/stats/#{site.domain}/pages?#{@range}")
        |> json_response(200)
        |> Map.get("results")

      refute Map.has_key?(row, "human_visitors")
    end
  end

  describe "main graph" do
    test "returns suspicious and bot series aligned with labels", %{conn: conn, site: site} do
      populate_mixed(site)

      res =
        conn
        |> get("/api/stats/#{site.domain}/main-graph?#{@range}&metric=visitors&interval=day")
        |> json_response(200)

      assert res["labels"] == ["2021-01-01", "2021-01-02"]
      assert res["plot"] == [2, 0]
      assert res["traffic_plot"] == %{"suspicious" => [1, 0], "bot" => [0, 2]}
    end

    test "has no traffic series when not looking at humans", %{conn: conn, site: site} do
      populate_mixed(site)

      res =
        conn
        |> get(
          "/api/stats/#{site.domain}/main-graph?#{@range}&metric=visitors&interval=day&traffic=all"
        )
        |> json_response(200)

      assert res["plot"] == [3, 2]
      assert res["traffic_plot"] == nil
    end
  end

  describe "current visitors" do
    test "counts only humans, split on request", %{conn: conn, site: site} do
      now = NaiveDateTime.utc_now()

      populate_stats(site, [
        build(:pageview, user_id: 1, timestamp: now),
        build(:pageview, user_id: 2, timestamp: now, traffic: 1),
        build(:pageview, user_id: 3, timestamp: now, traffic: 2),
        build(:pageview, user_id: 4, timestamp: now, traffic: 2)
      ])

      assert conn
             |> get("/api/stats/#{site.domain}/current-visitors")
             |> json_response(200) == 1

      assert conn
             |> get("/api/stats/#{site.domain}/current-visitors?split=traffic")
             |> json_response(200) == %{"human" => 1, "suspicious" => 1, "bot" => 2}
    end
  end

  describe "suspicious visitors" do
    test "lists non-human visits with their reasons", %{conn: conn, site: site} do
      populate_stats(site, [
        build(:pageview, user_id: 1, timestamp: ~N[2021-01-01 00:00:00]),
        build(:pageview,
          user_id: 2,
          timestamp: ~N[2021-01-01 00:00:00],
          pathname: "/pricing",
          browser: "",
          traffic: 1
        )
        |> with_reasons(["datacenter_ip", "unknown_ua"]),
        build(:pageview,
          user_id: 3,
          timestamp: ~N[2021-01-02 00:00:00],
          pathname: "/wp-login.php",
          traffic: 2
        )
        |> with_reasons(["headless_ua", "datacenter_ip"])
      ])

      res =
        conn
        |> get("/api/stats/#{site.domain}/suspicious-visitors?#{@range}")
        |> json_response(200)

      assert res["total"] == 2

      assert [
               %{
                 "class" => "bot",
                 "entry_page" => "/wp-login.php",
                 "reasons" => ["headless_ua", "datacenter_ip"]
               },
               %{"class" => "suspicious", "entry_page" => "/pricing", "browser" => nil}
             ] = res["visits"]

      assert res["reasons"] == [
               %{"reason" => "datacenter_ip", "visits" => 2},
               %{"reason" => "headless_ua", "visits" => 1},
               %{"reason" => "unknown_ua", "visits" => 1}
             ]

      assert %{"total" => 1, "visits" => [%{"class" => "bot"}]} =
               conn
               |> get("/api/stats/#{site.domain}/suspicious-visitors?#{@range}&traffic=bot")
               |> json_response(200)
    end
  end
end
