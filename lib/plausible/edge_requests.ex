defmodule Plausible.EdgeRequests.Row do
  @moduledoc "HTML requests Cloudflare served for a site on one UTC day, by agent."
  use Ecto.Schema

  schema "edge_requests" do
    belongs_to(:site, Plausible.Site)
    field(:date, :date)
    field(:agent, :string)
    field(:category, :string)
    field(:requests, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Plausible.EdgeRequests do
  @moduledoc """
  HTML page requests seen at the Cloudflare edge, by crawler (docs/edge-requests.md).

  The tracker only sees visitors that run JavaScript. Crawlers that don't (AI
  training and AI search bots, link previews, SEO tools, scrapers behind a
  browser user agent) only show up in the CDN's logs. This reads Cloudflare's
  GraphQL analytics (`httpRequestsAdaptiveGroups`, available on the free plan
  for the last 30 days) for every site whose domain belongs to a zone the
  token can read, and keeps daily counts here so they outlive Cloudflare's
  retention.

  Counts are Cloudflare's sampled estimates of HTML responses to real clients
  (`requestSource: eyeball`) on the site's host and its `www.` twin, per UTC day.
  Off unless `CLOUDFLARE_API_TOKEN` is set. Sites on several Cloudflare
  accounts: give one token per account, separated by commas; each zone is read
  with the token that listed it.
  """
  import Ecto.Query

  alias Plausible.EdgeRequests.{Agents, Row}
  alias Plausible.Repo

  @api "https://api.cloudflare.com/client/v4"
  @top_agents 10_000

  @query """
  query($zone: String!, $since: Date!, $until: Date!, $hosts: [String!]) {
    viewer {
      zones(filter: {zoneTag: $zone}) {
        totals: httpRequestsAdaptiveGroups(limit: 1000, filter: {date_geq: $since, date_leq: $until, clientRequestHTTPHost_in: $hosts, edgeResponseContentTypeName: "html", requestSource: "eyeball"}) {
          count
          dimensions { date }
        }
        agents: httpRequestsAdaptiveGroups(limit: #{@top_agents}, orderBy: [count_DESC], filter: {date_geq: $since, date_leq: $until, clientRequestHTTPHost_in: $hosts, edgeResponseContentTypeName: "html", requestSource: "eyeball"}) {
          count
          dimensions { date userAgent }
        }
      }
    }
  }
  """

  def enabled?, do: tokens() != []

  defp tokens do
    (Keyword.get(config(), :token) || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp config, do: Application.get_env(:plausible, __MODULE__, [])

  @doc "Fetches the last `days` UTC days (today included) for every site with a zone."
  def sync_all(today \\ Date.utc_today(), days \\ 3) do
    with true <- enabled?(),
         {:ok, zones} <- zones() do
      sites = Repo.all(from(s in Plausible.Site, select: %{id: s.id, domain: s.domain}))

      for site <- sites, zone = find_zone(site.domain, zones), zone != nil do
        {site.domain, sync_site(site, zone, today, days)}
      end
    else
      false -> {:error, :disabled}
      error -> error
    end
  end

  @doc """
  Fetches and stores one site's days from a zone (`%{id, token}` from
  `zones/0`, or a zone id read with the first token). Returns `{:ok, rows}`
  or `{:error, reason}`.
  """
  def sync_site(site, zone_id, today, days) when is_binary(zone_id) do
    sync_site(site, %{id: zone_id, token: hd(tokens())}, today, days)
  end

  def sync_site(site, %{id: zone_id, token: token}, today, days) do
    since = Date.add(today, -(days - 1))

    with {:ok, data} <- fetch(token, zone_id, hosts(site.domain), since, today) do
      rows = rows(data, site.id)

      Repo.transaction(fn ->
        Repo.delete_all(
          from(r in Row, where: r.site_id == ^site.id and r.date >= ^since and r.date <= ^today)
        )

        now = DateTime.utc_now()
        Repo.insert_all(Row, Enum.map(rows, &Map.put(&1, :inserted_at, now)))
      end)

      {:ok, length(rows)}
    end
  end

  def hosts(domain) do
    bare = String.replace_prefix(domain, "www.", "")
    Enum.uniq([domain, bare, "www." <> bare])
  end

  @doc "The zone id whose name is the longest suffix of `domain`, or nil."
  def zone_for(domain, zones) do
    case find_zone(domain, zones) do
      nil -> nil
      %{id: id} -> id
    end
  end

  defp find_zone(domain, zones) do
    zones
    |> Enum.filter(fn %{name: name} ->
      domain == name or String.ends_with?(domain, "." <> name)
    end)
    |> Enum.max_by(&String.length(&1.name), fn -> nil end)
  end

  @doc """
  All zones the tokens can read, as `[%{id, name, token}]`. A token that fails
  is skipped while another one works, so one revoked token doesn't stop the
  other accounts.
  """
  def zones do
    results = Enum.map(tokens(), &zones(&1, 1, []))

    case Enum.filter(results, &match?({:ok, _}, &1)) do
      [] -> List.first(results, {:error, :disabled})
      ok -> {:ok, ok |> Enum.flat_map(fn {:ok, zs} -> zs end) |> Enum.uniq_by(& &1.id)}
    end
  end

  defp zones(token, page, acc) do
    case request(token, :get, "/zones", params: [per_page: 50, page: page]) do
      {:ok, %{"result" => result, "result_info" => info}} when is_list(result) ->
        acc = acc ++ Enum.map(result, &%{id: &1["id"], name: &1["name"], token: token})

        if page < (info["total_pages"] || 1),
          do: zones(token, page + 1, acc),
          else: {:ok, acc}

      {:ok, _} ->
        {:error, "Cloudflare returned no zones."}

      error ->
        error
    end
  end

  defp fetch(token, zone_id, hosts, since, until) do
    body = %{
      query: @query,
      variables: %{
        zone: zone_id,
        since: Date.to_iso8601(since),
        until: Date.to_iso8601(until),
        hosts: hosts
      }
    }

    case request(token, :post, "/graphql", json: body) do
      {:ok, %{"data" => %{"viewer" => %{"zones" => [zone]}}, "errors" => errors}}
      when errors in [nil, []] ->
        {:ok, zone}

      {:ok, %{"errors" => [%{"message" => message} | _]}} ->
        {:error, "Cloudflare: #{message}"}

      {:ok, _} ->
        {:error, "Cloudflare returned no data for the zone."}

      error ->
        error
    end
  end

  defp request(token, method, path, opts) do
    req =
      [
        method: method,
        url: @api <> path,
        headers: [{"authorization", "Bearer #{token}"}],
        receive_timeout: 30_000,
        retry: false
      ] ++ opts ++ Keyword.take(config(), [:plug])

    case Req.request(req) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "Cloudflare answered HTTP #{status}."}
      {:error, _} -> {:error, "Could not reach Cloudflare."}
    end
  end

  # Named agents from the top user agents; the long tail Cloudflare didn't list
  # (beyond the top #{@top_agents}) is counted as browsers.
  defp rows(%{"totals" => totals, "agents" => agents}, site_id) do
    # One row per (date, agent), the key of the table's unique index. Several
    # user agent strings can map to the same agent with different categories;
    # the category with the most requests wins.
    agents =
      Enum.map(agents, fn %{"count" => count, "dimensions" => d} ->
        {Date.from_iso8601!(d["date"]), d["userAgent"], count}
      end)

    classified = classify(agents)

    named =
      agents
      |> Enum.reduce(%{}, fn {date, ua, count}, acc ->
        {agent, category} = Map.fetch!(classified, {ua, date})
        Map.update(acc, {date, agent, category}, count, &(&1 + count))
      end)
      |> Enum.group_by(fn {{date, agent, _}, _} -> {date, agent} end)
      |> Map.new(fn {{date, agent}, entries} ->
        {{_, _, category}, _} = Enum.max_by(entries, fn {_, count} -> count end)
        requests = entries |> Enum.map(fn {_, count} -> count end) |> Enum.sum()
        {{date, agent, category}, requests}
      end)

    seen =
      Enum.reduce(named, %{}, fn {{date, _, _}, count}, acc ->
        Map.update(acc, date, count, &(&1 + count))
      end)

    rest =
      for %{"count" => total, "dimensions" => %{"date" => day}} <- totals,
          date = Date.from_iso8601!(day),
          total > Map.get(seen, date, 0),
          into: %{} do
        {{date, "Browsers", "browser"}, total - Map.get(seen, date, 0)}
      end

    Map.merge(named, rest, fn _, a, b -> a + b end)
    |> Enum.map(fn {{date, agent, category}, requests} ->
      %{site_id: site_id, date: date, agent: agent, category: category, requests: requests}
    end)
  end

  # Up to 10,000 user agents per site; classify them on all cores.
  defp classify(agents) do
    agents
    |> Enum.map(fn {date, ua, _} -> {ua, date} end)
    |> Enum.uniq()
    |> Task.async_stream(fn {ua, date} -> {{ua, date}, Agents.classify(ua, date)} end,
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Map.new(fn {:ok, pair} -> pair end)
  end

  @doc "Stored rows for the site's last `days` UTC days ending `today`."
  def report(site_id, days, today \\ Date.utc_today()) do
    since = Date.add(today, -(days - 1))

    rows =
      Repo.all(
        from(r in Row,
          where: r.site_id == ^site_id and r.date >= ^since and r.date <= ^today,
          select: %{date: r.date, agent: r.agent, category: r.category, requests: r.requests}
        )
      )

    total = sum(rows)

    categories =
      rows
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, rs} -> {category, sum(rs)} end)
      |> Map.new()

    agents =
      rows
      |> Enum.reject(&(&1.category == "browser"))
      |> Enum.group_by(&{&1.agent, &1.category})
      |> Enum.map(fn {{agent, category}, rs} ->
        %{agent: agent, category: category, requests: sum(rs)}
      end)
      |> Enum.sort_by(& &1.requests, :desc)

    daily =
      rows
      |> Enum.group_by(& &1.date)
      |> Map.new(fn {date, rs} ->
        {date,
         rs
         |> Enum.group_by(& &1.category)
         |> Map.new(fn {c, crs} -> {c, sum(crs)} end)}
      end)

    %{
      since: since,
      until: today,
      total: total,
      categories: categories,
      agents: agents,
      daily: daily,
      synced_at:
        Repo.one(from(r in Row, where: r.site_id == ^site_id, select: max(r.inserted_at)))
    }
  end

  defp sum(rows), do: Enum.reduce(rows, 0, &(&1.requests + &2))
end
