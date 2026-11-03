defmodule PlausibleWeb.Api.ReplayController do
  @moduledoc """
  Receives session recording batches from a site's recorder (`POST /api/replay`). The body is
  read here, up to `Plausible.Replays.max_body/0`, since `text/plain` passes the parsers.
  """
  use PlausibleWeb, :controller

  def ingest(conn, params) do
    case Plug.Conn.read_body(conn, length: Plausible.Replays.max_body()) do
      {:ok, body, conn} ->
        ua = conn |> get_req_header("user-agent") |> List.first()

        case Plausible.Replays.ingest(params, body, ua) do
          result when result in [:ok, :ignored] -> send_resp(conn, 202, "")
          {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
        end

      {:more, _partial, conn} ->
        conn |> put_status(413) |> json(%{error: "too large"})

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "unreadable body"})
    end
  end
end
