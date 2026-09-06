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
end
