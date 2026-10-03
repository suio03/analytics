defmodule PlausibleWeb.Api.AdminEventsControllerTest do
  use PlausibleWeb.ConnCase, async: false

  setup [:create_user]

  setup %{conn: conn, user: user} do
    api_key = insert(:api_key, user: user)
    conn = put_req_header(conn, "authorization", "Bearer #{api_key.key}")
    {:ok, conn: conn, api_key: api_key}
  end

  describe "authentication and sites" do
    test "requires an API key", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> get("/api/v1/admin/sites")

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "lists every site available to the account", %{conn: conn, user: user} do
      insert(:site, domain: "b.example", timezone: "Etc/UTC", members: [user])
      insert(:site, domain: "a.example", timezone: "Europe/Tallinn", members: [user])
      insert(:site, domain: "private.example", members: [])

      conn = get(conn, "/api/v1/admin/sites")

      assert json_response(conn, 200) == %{
               "sites" => [
                 %{"domain" => "a.example", "timezone" => "Europe/Tallinn"},
                 %{"domain" => "b.example", "timezone" => "Etc/UTC"}
               ]
             }
    end
  end

  describe "event goals" do
    setup :create_site

    test "adds event goals idempotently and lists only event goals", %{conn: conn, site: site} do
      insert(:goal, site: site, page_path: "/pricing")

      conn =
        post(conn, "/api/v1/admin/events", %{
          site_id: site.domain,
          events: [" Signup ", "Purchase", "Signup"]
        })

      assert %{
               "created" => ["Purchase", "Signup"],
               "deleted" => [],
               "events" => [
                 %{"event_name" => "Purchase"},
                 %{"event_name" => "Signup"}
               ]
             } = json_response(conn, 200)

      conn =
        post(recycle(conn), "/api/v1/admin/events", %{
          site_id: site.domain,
          events: ["Signup"]
        })

      assert %{"created" => [], "deleted" => []} = json_response(conn, 200)

      conn = get(recycle(conn), "/api/v1/admin/events", %{site_id: site.domain})

      assert %{
               "events" => [
                 %{"event_name" => "Purchase"},
                 %{"event_name" => "Signup"}
               ]
             } = json_response(conn, 200)
    end

    test "sync is additive unless prune is explicitly enabled", %{conn: conn, site: site} do
      insert(:goal, site: site, event_name: "Keep")
      insert(:goal, site: site, event_name: "Remove")
      page_goal = insert(:goal, site: site, page_path: "/keep-page")

      conn =
        put(conn, "/api/v1/admin/events", %{
          site_id: site.domain,
          events: ["Keep", "New"]
        })

      assert %{"created" => ["New"], "deleted" => []} = json_response(conn, 200)

      conn =
        put(recycle(conn), "/api/v1/admin/events", %{
          site_id: site.domain,
          events: ["Keep"],
          prune: true
        })

      assert %{
               "created" => [],
               "deleted" => ["New", "Remove"],
               "events" => [%{"event_name" => "Keep"}]
             } = json_response(conn, 200)

      assert Plausible.Repo.reload(page_goal)
    end

    test "deletes an event goal but refuses to delete a pageview goal", %{conn: conn, site: site} do
      event_goal = insert(:goal, site: site, event_name: "Signup")
      page_goal = insert(:goal, site: site, page_path: "/pricing")

      conn =
        delete(conn, "/api/v1/admin/events/#{event_goal.id}", %{site_id: site.domain})

      assert json_response(conn, 200) == %{"deleted" => true}
      refute Plausible.Repo.reload(event_goal)

      conn =
        delete(recycle(conn), "/api/v1/admin/events/#{page_goal.id}", %{site_id: site.domain})

      assert %{"error" => "Event goal not found"} = json_response(conn, 404)
      assert Plausible.Repo.reload(page_goal)
    end

    test "viewer API keys cannot change goals", %{conn: conn, user: user, site: site} do
      membership =
        Plausible.Repo.get_by!(Plausible.Site.Membership, user_id: user.id, site_id: site.id)

      membership |> Ecto.Changeset.change(role: :viewer) |> Plausible.Repo.update!()

      conn =
        post(conn, "/api/v1/admin/events", %{
          site_id: site.domain,
          events: ["Signup"]
        })

      assert %{"error" => _} = json_response(conn, 404)
      assert Plausible.Goals.for_site(site) == []
    end

    test "validates request data", %{conn: conn, site: site} do
      conn = post(conn, "/api/v1/admin/events", %{site_id: site.domain, events: [""]})
      assert %{"error" => "Event names cannot be blank"} = json_response(conn, 400)

      conn = put(recycle(conn), "/api/v1/admin/events", %{site_id: site.domain, events: []})
      assert %{"events" => []} = json_response(conn, 200)
    end
  end

  describe "custom properties" do
    setup :create_site

    test "batch add preserves existing properties and is idempotent", %{conn: conn, site: site} do
      site
      |> Ecto.Changeset.change(allowed_event_props: ["tool_slug"])
      |> Plausible.Repo.update!()

      params = %{site_id: site.domain, properties: [" outcome ", "stage", "outcome"]}
      response = post(conn, "/api/v1/admin/properties", params)

      assert %{"properties" => ["outcome", "stage", "tool_slug"], "added" => ["outcome", "stage"]} =
               json_response(response, 200)

      response = post(recycle(conn), "/api/v1/admin/properties", params)
      assert %{"added" => []} = json_response(response, 200)

      response = get(recycle(conn), "/api/v1/admin/properties", %{site_id: site.domain})
      assert %{"properties" => ["outcome", "stage", "tool_slug"]} = json_response(response, 200)
    end

    test "invalid batches are atomic", %{conn: conn, site: site} do
      site
      |> Ecto.Changeset.change(allowed_event_props: ["tool_slug"])
      |> Plausible.Repo.update!()

      for properties <- [
            nil,
            "stage",
            [1],
            ["stage", " "],
            [String.duplicate("x", 301)],
            Enum.map(1..301, &"prop_#{&1}")
          ] do
        response =
          post(recycle(conn), "/api/v1/admin/properties", %{
            site_id: site.domain,
            properties: properties
          })

        assert %{"error" => _} = json_response(response, 400)
        assert Plausible.Repo.reload(site).allowed_event_props == ["tool_slug"]
      end
    end

    test "combined property limit leaves settings unchanged", %{conn: conn, site: site} do
      existing = Enum.map(1..300, &"prop_#{&1}")
      site |> Ecto.Changeset.change(allowed_event_props: existing) |> Plausible.Repo.update!()

      response =
        post(conn, "/api/v1/admin/properties", %{site_id: site.domain, properties: ["stage"]})

      assert %{"error" => _} = json_response(response, 400)
      assert Plausible.Repo.reload(site).allowed_event_props == existing
    end

    test "requires authentication and editable site membership", %{
      conn: conn,
      user: user,
      site: site
    } do
      unauthenticated = conn |> delete_req_header("authorization")

      assert unauthenticated
             |> get("/api/v1/admin/properties", %{site_id: site.domain})
             |> json_response(401)

      assert unauthenticated
             |> post("/api/v1/admin/properties", %{site_id: site.domain, properties: ["stage"]})
             |> json_response(401)

      membership =
        Plausible.Repo.get_by!(Plausible.Site.Membership, user_id: user.id, site_id: site.id)

      membership |> Ecto.Changeset.change(role: :viewer) |> Plausible.Repo.update!()

      response =
        post(recycle(conn), "/api/v1/admin/properties", %{
          site_id: site.domain,
          properties: ["stage"]
        })

      assert %{"error" => _} = json_response(response, 404)
      response = get(recycle(conn), "/api/v1/admin/properties", %{site_id: site.domain})
      assert %{"error" => _} = json_response(response, 404)
    end
  end

  describe "paths" do
    setup %{user: user} do
      site = insert(:site, domain: "paths.example", timezone: "Etc/UTC", members: [user])
      {:ok, site: site}
    end

    defp visit(site, started_at, steps) do
      session_id = System.unique_integer([:positive])

      steps
      |> Enum.map(fn {offset, attrs} ->
        build(
          :event,
          Keyword.merge(
            [
              name: "pageview",
              session_id: session_id,
              user_id: session_id,
              timestamp: NaiveDateTime.add(started_at, offset),
              referrer_source: "Google",
              screen_size: "Desktop"
            ],
            attrs
          )
        )
      end)
      |> then(&populate_stats(site, &1))
    end

    setup %{site: site} do
      day = ~N[2026-09-10 08:00:00]

      visit(site, day, [
        {0, pathname: "/ja"},
        {5, pathname: "/ja"},
        {10, name: "transcribe_success", pathname: "/ja"},
        {40, pathname: "/pricing"},
        {50,
         name: "checkout_click",
         pathname: "/pricing",
         "meta.key": ["tier", "transaction_id"],
         "meta.value": ["pro", "txn_01abc"]}
      ])

      visit(site, NaiveDateTime.add(day, 3600), [
        {0, pathname: "/"},
        {20, name: "transcribe_success", pathname: "/"},
        {30, pathname: "/dashboard/transcripts/cfbec2a4-4a01-4a4d-82f9-731d6ead8739"}
      ])

      visit(site, NaiveDateTime.add(day, 7200), [{0, pathname: "/"}])
      visit(site, ~N[2026-08-01 08:00:00], [{0, pathname: "/old"}])

      other = insert(:site, members: [])
      visit(other, day, [{0, pathname: "/other-site"}])
      :ok
    end

    @range %{from: "2026-09-01", to: "2026-09-30"}

    test "top mode groups normalized visits within the range", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/admin/paths", Map.put(@range, :site_id, site.domain))

      assert %{
               "mode" => "top",
               "sessions_matched" => 3,
               "truncated" => false,
               "paths" => [
                 %{"path" => ["/"], "sessions" => 1},
                 %{
                   "path" => ["/", "transcribe_success", "/dashboard/transcripts/:id"],
                   "sessions" => 1
                 },
                 %{
                   "path" => ["/", "transcribe_success", "/pricing", "checkout_click"],
                   "sessions" => 1
                 }
               ]
             } = json_response(conn, 200)
    end

    test "sessions mode filters by contained events and hides identifiers", %{
      conn: conn,
      site: site
    } do
      params =
        Map.merge(@range, %{
          site_id: site.domain,
          mode: "sessions",
          contains: "checkout_click",
          props: "tier,transaction"
        })

      response = conn |> get("/api/v1/admin/paths", params) |> json_response(200)

      assert response["sessions"] == [
               %{
                 "date" => "2026-09-10",
                 "source" => "Google",
                 "device" => "Desktop",
                 "steps" => [
                   ["/", 0],
                   ["transcribe_success", 10],
                   ["/pricing", 40],
                   ["checkout_click(tier=pro)", 50]
                 ]
               }
             ]

      refute Jason.encode!(response) =~ "txn_01abc"
    end

    test "next and prev modes count neighbouring steps", %{conn: conn, site: site} do
      params =
        Map.merge(@range, %{site_id: site.domain, mode: "next", step: "transcribe_success"})

      response = conn |> get("/api/v1/admin/paths", params) |> json_response(200)

      assert response["occurrences"] == 2

      assert response["steps"] == [
               %{"step" => "/dashboard/transcripts/:id", "count" => 1, "share" => 0.5},
               %{"step" => "/pricing", "count" => 1, "share" => 0.5}
             ]

      params = Map.merge(@range, %{site_id: site.domain, mode: "prev", step: "/ja"})
      response = recycle(conn) |> get("/api/v1/admin/paths", params) |> json_response(200)

      assert response["step"] == "/"
      assert response["steps"] == [%{"step" => "(entry)", "count" => 3, "share" => 1.0}]
    end

    test "rejects invalid params", %{conn: conn, site: site} do
      for {params, message} <- [
            {%{mode: "graph"}, "mode"},
            {%{mode: "next"}, "step"},
            {%{from: "2026-01-01", to: "2026-09-30"}, "90 days"},
            {%{from: "2026-09-30", to: "2026-09-01"}, "after"},
            {%{to: "yesterday"}, "ISO 8601"},
            {%{limit: "0"}, "limit"},
            {%{props: "error_message"}, "props"},
            {%{props: "user_id"}, "props"}
          ] do
        response =
          conn
          |> recycle()
          |> get("/api/v1/admin/paths", Map.put(params, :site_id, site.domain))
          |> json_response(400)

        assert response["error"] =~ message
      end
    end

    test "viewer API keys cannot read paths", %{conn: conn, user: user, site: site} do
      Plausible.Repo.get_by!(Plausible.Site.Membership, user_id: user.id, site_id: site.id)
      |> Ecto.Changeset.change(role: :viewer)
      |> Plausible.Repo.update!()

      conn = get(conn, "/api/v1/admin/paths", %{site_id: site.domain})
      assert %{"error" => _} = json_response(conn, 404)
    end
  end
end
