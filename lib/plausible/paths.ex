defmodule Plausible.Paths do
  @moduledoc """
  Reconstructs anonymized, per-visit event sequences for the admin API.

  Events are read from ClickHouse ordered by session and time, then normalized:
  locale prefixes are dropped, IDs in paths become `:id`, consecutive repeats
  collapse into one step and only requested props with enum-like values are
  kept. Session and user identifiers never leave this module.

  Sessions only span one visit; Plausible rotates visitor hashes daily, so
  visits by the same person on different days cannot be linked.
  """

  import Ecto.Query

  @modes ~w(top sessions next prev)
  @default_days 30
  @max_days 90
  @default_limit 50
  @max_limit 500
  @max_steps 30
  @max_events 500_000
  @max_filter_items 50

  @locales ~w(ar bg cs da de el en es et fi fr he hi hu id it ja ko lt lv ms nb nl no pl pt ro ru sk sl sr sv th tr uk vi zh)
  @locale_pattern Enum.join(@locales, "|")
  @locale_regex ~r"^/(?:#{@locale_pattern})(?:-[a-zA-Z]{2,4})?(?=/|$)"
  @uuid_regex ~r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"i
  @token_regex ~r"^(?=.*\d)[A-Za-z0-9_-]{16,}$"
  @prop_value_regex ~r"^[A-Za-z0-9_.:-]{1,40}$"
  @sensitive_prop_regex ~r"(^id$|_id$|email|url|message|name|token|query|search|title|path)"i

  @doc """
  Validates admin API params and returns path data for the site.
  """
  def query(%Plausible.Site{} = site, params, today \\ nil) do
    today = today || DateTime.now!(site.timezone) |> DateTime.to_date()

    with {:ok, mode} <- fetch_mode(params),
         {:ok, {from, to}} <- fetch_range(params, today),
         {:ok, limit} <- fetch_limit(params),
         {:ok, contains} <- fetch_list(params, "contains"),
         {:ok, props} <- fetch_props(params),
         {:ok, step} <- fetch_step(params, mode) do
      {sessions, truncated?} = load_sessions(site, from, to, contains, props)

      {:ok,
       %{
         site_id: site.domain,
         mode: mode,
         from: Date.to_iso8601(from),
         to: Date.to_iso8601(to),
         sessions_matched: length(sessions),
         truncated: truncated?
       }
       |> Map.merge(summarize(mode, sessions, limit, step))}
    end
  end

  defp summarize("top", sessions, limit, _step) do
    paths =
      sessions
      |> Enum.frequencies_by(fn s -> Enum.map(s.steps, &elem(&1, 0)) end)
      |> Enum.sort_by(fn {path, count} -> {-count, path} end)
      |> Enum.take(limit)
      |> Enum.map(fn {path, count} -> %{path: path, sessions: count} end)

    %{paths: paths}
  end

  defp summarize("sessions", sessions, limit, _step) do
    rows =
      sessions
      |> Enum.sort_by(& &1.started_at, {:desc, NaiveDateTime})
      |> Enum.take(limit)
      |> Enum.map(fn s ->
        %{
          date: NaiveDateTime.to_date(s.started_at) |> Date.to_iso8601(),
          source: s.source,
          device: s.device,
          steps: Enum.map(s.steps, fn {label, offset} -> [label, offset] end)
        }
      end)

    %{sessions: rows}
  end

  defp summarize(mode, sessions, limit, step) when mode in ["next", "prev"] do
    neighbours =
      Enum.flat_map(sessions, fn s ->
        labels = Enum.map(s.steps, &elem(&1, 0))
        labels = if mode == "prev", do: Enum.reverse(labels), else: labels
        boundary = if mode == "prev", do: "(entry)", else: "(exit)"

        labels
        |> Enum.chunk_every(2, 1, [boundary])
        |> Enum.filter(fn [label, _] -> step_matches?(label, step) end)
        |> Enum.map(fn [_, neighbour] -> neighbour end)
      end)

    total = length(neighbours)

    steps =
      neighbours
      |> Enum.frequencies()
      |> Enum.sort_by(fn {label, count} -> {-count, label} end)
      |> Enum.take(limit)
      |> Enum.map(fn {label, count} ->
        %{step: label, count: count, share: Float.round(count / total, 3)}
      end)

    %{step: step, occurrences: total, steps: steps}
  end

  # A bare event name also matches its labels with props, e.g. `upgrade_cta_shown(reason=quota)`.
  defp step_matches?(label, step), do: label == step or String.starts_with?(label, step <> "(")

  defp load_sessions(site, from, to, contains, props) do
    {first, last} = utc_bounds(site, from, to)

    query =
      from(e in Plausible.ClickhouseEventV2,
        where: e.site_id == ^site.id,
        where: e.timestamp >= ^first and e.timestamp < ^last,
        where: e.name != "engagement",
        order_by: [asc: e.session_id, asc: e.timestamp],
        limit: ^(@max_events + 1),
        select: {
          e.session_id,
          e.timestamp,
          e.name,
          e.pathname,
          field(e, :"meta.key"),
          field(e, :"meta.value"),
          e.referrer_source,
          e.screen_size
        }
      )

    query =
      if contains == [] do
        query
      else
        matching =
          from(e in Plausible.ClickhouseEventV2,
            where: e.site_id == ^site.id,
            where: e.timestamp >= ^first and e.timestamp < ^last,
            where: e.name in ^contains,
            select: e.session_id
          )

        where(query, [e], e.session_id in subquery(matching))
      end

    rows = Plausible.ClickhouseRepo.all(query)
    truncated? = length(rows) > @max_events

    sessions =
      rows
      |> Enum.take(@max_events)
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(&build_session(&1, props))

    {sessions, truncated?}
  end

  defp build_session([{_, started_at, _, _, _, _, source, device} | _] = events, props) do
    steps =
      events
      |> Enum.map(fn {_, timestamp, name, pathname, keys, values, _, _} ->
        {step_label(name, pathname, keys, values, props),
         NaiveDateTime.diff(timestamp, started_at)}
      end)
      |> Enum.dedup_by(&elem(&1, 0))
      |> Enum.take(@max_steps)

    %{
      started_at: started_at,
      source: blank_to(source, "Direct / None"),
      device: blank_to(device, "(unknown)"),
      steps: steps
    }
  end

  @doc false
  def step_label("pageview", pathname, _keys, _values, _props), do: normalize_path(pathname)

  def step_label(name, _pathname, keys, values, props) do
    kept =
      Enum.zip(keys || [], values || [])
      |> Enum.filter(fn {key, value} ->
        key in props and Regex.match?(@prop_value_regex, value)
      end)
      |> Enum.sort()
      |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

    if kept == "", do: name, else: "#{name}(#{kept})"
  end

  @doc false
  def normalize_path(pathname) when is_binary(pathname) do
    path =
      pathname
      |> String.split(["?", "#"], parts: 2)
      |> hd()
      |> String.replace(@locale_regex, "")

    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn segment ->
        cond do
          Regex.match?(@uuid_regex, segment) -> ":id"
          Regex.match?(~r/^\d+$/, segment) -> ":id"
          Regex.match?(@token_regex, segment) -> ":id"
          true -> segment
        end
      end)

    "/" <> Enum.join(segments, "/")
  end

  def normalize_path(_pathname), do: "/"

  defp utc_bounds(site, from, to) do
    to_utc = fn date ->
      date
      |> DateTime.new!(~T[00:00:00], site.timezone)
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.to_naive()
    end

    {to_utc.(from), to_utc.(Date.add(to, 1))}
  end

  defp fetch_mode(params) do
    mode = Map.get(params, "mode", "top")
    if mode in @modes, do: {:ok, mode}, else: {:error, :invalid_mode}
  end

  defp fetch_range(params, today) do
    with {:ok, to} <- parse_date(params["to"], today),
         {:ok, from} <- parse_date(params["from"], Date.add(to, -(@default_days - 1))) do
      cond do
        Date.compare(from, to) == :gt -> {:error, :invalid_range}
        Date.diff(to, from) >= @max_days -> {:error, :range_too_long}
        true -> {:ok, {from, to}}
      end
    end
  end

  defp parse_date(nil, default), do: {:ok, default}

  defp parse_date(value, _default) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_value, _default), do: {:error, :invalid_date}

  defp fetch_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        {:ok, @default_limit}

      value ->
        case Integer.parse(to_string(value)) do
          {limit, ""} when limit in 1..@max_limit -> {:ok, limit}
          _ -> {:error, :invalid_limit}
        end
    end
  end

  defp fetch_list(params, key) do
    items =
      case Map.get(params, key) do
        nil -> []
        value when is_binary(value) -> String.split(value, ",")
        value when is_list(value) -> value
        _ -> :invalid
      end

    with items when is_list(items) <- items,
         true <- Enum.all?(items, &is_binary/1),
         items = items |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
         true <- length(items) <= @max_filter_items do
      {:ok, items}
    else
      _ -> {:error, {:invalid_list, key}}
    end
  end

  defp fetch_props(params) do
    with {:ok, props} <- fetch_list(params, "props") do
      if Enum.any?(props, &Regex.match?(@sensitive_prop_regex, &1)),
        do: {:error, :sensitive_prop},
        else: {:ok, props}
    end
  end

  defp fetch_step(%{"step" => step}, mode) when mode in ["next", "prev"] and is_binary(step) do
    case String.trim(step) do
      "" -> {:error, :missing_step}
      "/" <> _ = path -> {:ok, normalize_path(path)}
      name -> {:ok, name}
    end
  end

  defp fetch_step(_params, mode) when mode in ["next", "prev"], do: {:error, :missing_step}
  defp fetch_step(_params, _mode), do: {:ok, nil}

  defp blank_to(value, default) when value in [nil, ""], do: default
  defp blank_to(value, _default), do: value
end
