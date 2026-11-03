defmodule Plausible.Replays do
  @moduledoc """
  Session recordings: rrweb event batches posted by a site's recorder, stored in ClickHouse
  for 30 days and read back whole for the admin API.

  The recorder masks typed values and page copy before anything leaves the browser; this module
  checks the shape of what arrives and never parses the events beyond their type and time.
  A batch is gzip or, for the last one of a page, plain JSON (see the recorder).
  """

  import Ecto.Query

  alias Plausible.Replays.Chunk

  # Gzipped batches above this are refused; the recorder flushes every few seconds.
  @max_body 1_000_000
  @max_json 20_000_000
  @max_events 50_000
  @id_regex ~r/^[A-Za-z0-9_-]{8,64}$/
  @max_seq 100_000
  @default_days 7
  @max_days 30
  @default_limit 50
  @max_limit 500

  def max_body, do: @max_body

  @doc """
  Validates one posted batch and stores it. Returns `:ok`, `:ignored` (unknown site or a bot,
  answered like a success so recorders don't retry) or `{:error, reason}`.
  """
  def ingest(params, body, user_agent) do
    with {:ok, ids} <- fetch_ids(params),
         :ok <- check_agent(user_agent),
         {:ok, site_id} <- fetch_site(params["s"]),
         {:ok, text} <- decode(body),
         {:ok, {count, first, last}} <- validate(text) do
      Plausible.IngestRepo.insert_all(Chunk, [
        Map.merge(ids, %{
          site_id: site_id,
          started_at: DateTime.from_unix!(first * 1000, :microsecond),
          ended_at: DateTime.from_unix!(last * 1000, :microsecond),
          events: count,
          data: text
        })
      ])

      :ok
    end
  end

  defp fetch_ids(params) do
    with vid when is_binary(vid) <- params["vid"],
         sid when is_binary(sid) <- params["sid"],
         load when is_binary(load) <- params["load"],
         true <- Enum.all?([vid, sid, load], &Regex.match?(@id_regex, &1)),
         {seq, ""} when seq in 0..@max_seq <- Integer.parse(params["seq"] || "") do
      {:ok, %{visitor_id: vid, session_id: sid, load_id: load, seq: seq}}
    else
      _ -> {:error, :invalid_parameters}
    end
  end

  defp check_agent(ua) when is_binary(ua) and ua != "" do
    case UAInspector.parse(ua) do
      %UAInspector.Result.Bot{} -> :ignored
      %UAInspector.Result{client: %UAInspector.Result.Client{name: "Headless Chrome"}} -> :ignored
      _ -> :ok
    end
  end

  defp check_agent(_), do: :ignored

  defp fetch_site(domain) when is_binary(domain) and byte_size(domain) in 1..253 do
    case Plausible.Site.Cache.get_site_id(domain) do
      nil -> :ignored
      id -> {:ok, id}
    end
  end

  defp fetch_site(_), do: {:error, :invalid_parameters}

  defp decode(<<0x1F, 0x8B, _::binary>> = body) do
    case gunzip(body) do
      {:ok, text} -> {:ok, String.trim(text)}
      :error -> {:error, :invalid_body}
    end
  end

  defp decode(body), do: {:ok, String.trim(body)}

  # Inflates in steps so a small body that expands without end is cut off at @max_json.
  defp gunzip(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, data), [], 0)
    rescue
      _ -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, out}, acc, size) when status in [:continue, :finished] do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_json -> :error
      status == :finished -> {:ok, IO.iodata_to_binary([acc, out])}
      true -> inflate(z, :zlib.safeInflate(z, []), [acc, out], size)
    end
  end

  defp inflate(_z, _other, _acc, _size), do: :error

  defp validate(text) do
    case Jason.decode(text) do
      {:ok, [_ | _] = events} when length(events) <= @max_events ->
        if Enum.all?(events, &event?/1) do
          times = Enum.map(events, &trunc(&1["timestamp"]))
          {:ok, {length(events), Enum.min(times), Enum.max(times)}}
        else
          {:error, :invalid_events}
        end

      _ ->
        {:error, :invalid_events}
    end
  end

  # A plausible millisecond timestamp: after 2020, before 2100.
  defp event?(%{"type" => type, "timestamp" => ts})
       when is_integer(type) and is_number(ts) and ts > 1_577_836_800_000 and
              ts < 4_102_444_800_000,
       do: true

  defp event?(_), do: false

  @doc """
  Recorded sessions received in the last `days` (default 7, at most 30), newest first, with
  their size. `visitor` narrows to one visitor's sessions.
  """
  def list(%Plausible.Site{} = site, params) do
    with {:ok, days} <- fetch_int(params, "days", @default_days, 1..@max_days),
         {:ok, limit} <- fetch_int(params, "limit", @default_limit, 1..@max_limit),
         {:ok, visitor} <- fetch_visitor(params) do
      since = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

      query =
        from(c in Chunk,
          where: c.site_id == ^site.id and c.received_at >= ^since,
          group_by: c.session_id,
          order_by: [desc: min(c.started_at)],
          limit: ^limit,
          select: %{
            session_id: c.session_id,
            visitor_id: fragment("any(?)", c.visitor_id),
            started_at: min(c.started_at),
            ended_at: max(c.ended_at),
            loads: fragment("uniqExact(?)", c.load_id),
            events: fragment("toUInt64(sum(?))", c.events),
            bytes: fragment("toUInt64(sum(length(?)))", c.data)
          }
        )

      query = if visitor, do: where(query, [c], c.visitor_id == ^visitor), else: query

      sessions =
        query
        |> Plausible.ClickhouseRepo.all()
        |> Enum.map(fn s ->
          %{
            s
            | started_at: to_iso(s.started_at),
              ended_at: to_iso(s.ended_at)
          }
        end)

      {:ok, %{site_id: site.domain, days: days, sessions: sessions}}
    end
  end

  @doc """
  One session's recording as a JSON array of page loads, each an array of rrweb events in
  order. Built from the stored text without decoding it again. `{:error, :not_found}` when
  nothing is stored.
  """
  def recording(%Plausible.Site{} = site, session_id) do
    if is_binary(session_id) and Regex.match?(@id_regex, session_id) do
      chunks =
        from(c in Chunk,
          where: c.site_id == ^site.id and c.session_id == ^session_id,
          select: {c.load_id, c.seq, c.started_at, c.visitor_id, c.data}
        )
        |> Plausible.ClickhouseRepo.all()

      case chunks do
        [] -> {:error, :not_found}
        [{_, _, _, visitor, _} | _] -> {:ok, visitor, assemble(chunks)}
      end
    else
      {:error, :not_found}
    end
  end

  defp assemble(chunks) do
    loads =
      chunks
      |> Enum.group_by(&elem(&1, 0))
      |> Map.values()
      |> Enum.map(fn load ->
        # A batch sent twice is stored twice until ClickHouse merges the parts.
        load |> Enum.uniq_by(&elem(&1, 1)) |> Enum.sort_by(&elem(&1, 1))
      end)
      |> Enum.sort_by(fn load -> load |> Enum.map(&unix_ms(elem(&1, 2))) |> Enum.min() end)
      |> Enum.map(fn load ->
        inner =
          Enum.map(load, fn {_, _, _, _, data} -> binary_part(data, 1, byte_size(data) - 2) end)

        ["[", Enum.intersperse(inner, ","), "]"]
      end)

    ["[", Enum.intersperse(loads, ","), "]"]
  end

  defp fetch_int(params, key, default, range) do
    case Integer.parse(to_string(params[key] || default)) do
      {n, ""} when is_integer(n) -> in_range(n, range, key)
      _ -> {:error, :"invalid_#{key}"}
    end
  end

  defp in_range(n, range, key) do
    if n in range, do: {:ok, n}, else: {:error, :"invalid_#{key}"}
  end

  defp fetch_visitor(%{"visitor" => v}) when is_binary(v) do
    if Regex.match?(@id_regex, v), do: {:ok, v}, else: {:error, :invalid_visitor}
  end

  defp fetch_visitor(_), do: {:ok, nil}

  defp unix_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp unix_ms(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> unix_ms()

  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
end
