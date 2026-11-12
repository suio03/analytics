defmodule Plausible.Workers.SyncEdgeRequests do
  @moduledoc """
  Copies the last three UTC days of Cloudflare edge HTML requests by crawler
  into `edge_requests` (see `Plausible.EdgeRequests`). Does nothing without
  `CLOUDFLARE_API_TOKEN`.
  """
  use Oban.Worker, queue: :edge_requests, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case Plausible.EdgeRequests.sync_all() do
      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("SyncEdgeRequests: #{reason}")
        :ok

      results ->
        for {domain, {:error, reason}} <- results do
          Logger.warning("SyncEdgeRequests: #{domain}: #{reason}")
        end

        :ok
    end
  end
end
