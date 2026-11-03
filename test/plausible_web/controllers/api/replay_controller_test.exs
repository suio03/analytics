defmodule PlausibleWeb.Api.ReplayControllerTest do
  use PlausibleWeb.ConnCase, async: false

  @chrome "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
  @now 1_793_700_000_000

  setup [:create_user]

  setup %{user: user} do
    site = insert(:site, domain: "replay.example", members: [user])
    {:ok, site: site}
  end

  defp events(from, n \\ 2),
    do: Enum.map(0..(n - 1), &%{type: 3, timestamp: from + &1 * 100, data: %{source: 1}})

  defp post_batch(conn, params, body) do
    conn
    |> put_req_header("user-agent", @chrome)
    |> put_req_header("content-type", "text/plain")
    |> post("/api/replay?" <> URI.encode_query(params), body)
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{s: "replay.example", vid: "visitor-0001", sid: "session-0001", load: "load-0001", seq: 0},
      overrides
    )
  end

  defp admin(conn, user) do
    api_key = insert(:api_key, user: user)
    put_req_header(conn, "authorization", "Bearer #{api_key.key}")
  end

  describe "POST /api/replay" do
    test "stores gzip and plain JSON batches and serves them back by page load", %{
      conn: conn,
      user: user
    } do
      gz = :zlib.gzip(Jason.encode!(events(@now)))
      assert conn |> post_batch(params(), gz) |> response(202)

      plain = Jason.encode!(events(@now + 1000, 1))
      assert recycle(conn) |> post_batch(params(%{seq: 1}), plain) |> response(202)

      # An earlier page load of the same session comes first.
      earlier = Jason.encode!(events(@now - 5000, 1))

      assert recycle(conn)
             |> post_batch(params(%{load: "load-0000"}), earlier)
             |> response(202)

      conn = recycle(conn) |> admin(user)

      assert %{"sessions" => [session]} =
               conn
               |> get("/api/v1/admin/replays", %{site_id: "replay.example"})
               |> json_response(200)

      assert %{"session_id" => "session-0001", "visitor_id" => "visitor-0001", "loads" => 2} =
               session

      assert session["events"] == 4

      assert %{"visitor_id" => "visitor-0001", "loads" => [first, second]} =
               recycle(conn)
               |> get("/api/v1/admin/replays/session-0001", %{site_id: "replay.example"})
               |> json_response(200)

      assert Enum.map(first, & &1["timestamp"]) == [@now - 5000]
      assert Enum.map(second, & &1["timestamp"]) == [@now, @now + 100, @now + 1000]
    end

    test "answers unknown sites and bots without storing", %{conn: conn, user: user} do
      body = Jason.encode!(events(@now))
      assert conn |> post_batch(params(%{s: "unknown.example"}), body) |> response(202)

      assert recycle(conn)
             |> put_req_header("user-agent", "Googlebot/2.1 (+http://www.google.com/bot.html)")
             |> put_req_header("content-type", "text/plain")
             |> post("/api/replay?" <> URI.encode_query(params()), body)
             |> response(202)

      assert %{"sessions" => []} =
               recycle(conn)
               |> admin(user)
               |> get("/api/v1/admin/replays", %{site_id: "replay.example"})
               |> json_response(200)
    end

    test "refuses bad ids, bodies that aren't rrweb events and oversized batches", %{conn: conn} do
      body = Jason.encode!(events(@now))
      assert conn |> post_batch(params(%{vid: "x"}), body) |> json_response(400)
      assert recycle(conn) |> post_batch(params(), ~s({"a":1})) |> json_response(400)
      assert recycle(conn) |> post_batch(params(), "[]") |> json_response(400)
      assert recycle(conn) |> post_batch(params(), ~s([{"type":3}])) |> json_response(400)
      assert recycle(conn) |> post_batch(params(), <<0x1F, 0x8B, 1, 2, 3>>) |> json_response(400)

      big = :crypto.strong_rand_bytes(Plausible.Replays.max_body() + 1)
      assert recycle(conn) |> post_batch(params(), big) |> json_response(413)
    end

    test "stops inflating a gzip bomb", %{conn: conn} do
      bomb = :zlib.gzip(String.duplicate(" ", 30_000_000))
      assert byte_size(bomb) < Plausible.Replays.max_body()
      assert conn |> post_batch(params(), bomb) |> json_response(400)
    end
  end

  describe "admin replays" do
    test "unknown sessions are not found", %{conn: conn, user: user} do
      conn = admin(conn, user)

      assert conn
             |> get("/api/v1/admin/replays/session-9999", %{site_id: "replay.example"})
             |> json_response(404)
    end

    test "viewer API keys cannot read recordings", %{conn: conn, user: user, site: site} do
      Plausible.Repo.get_by!(Plausible.Site.Membership, user_id: user.id, site_id: site.id)
      |> Ecto.Changeset.change(role: :viewer)
      |> Plausible.Repo.update!()

      conn = admin(conn, user)
      assert conn |> get("/api/v1/admin/replays", %{site_id: site.domain}) |> json_response(404)
    end

    test "validates days", %{conn: conn, user: user} do
      conn = admin(conn, user)

      assert conn
             |> get("/api/v1/admin/replays", %{site_id: "replay.example", days: 31})
             |> json_response(400)
    end
  end
end
