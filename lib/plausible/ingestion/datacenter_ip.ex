defmodule Plausible.Ingestion.DatacenterIP do
  @moduledoc """
  Tells whether an IP address belongs to a public cloud provider
  (AWS, Google Cloud, Oracle Cloud, DigitalOcean, Linode).

  Real visitors rarely browse from these networks, while headless browsers
  and scrapers mostly run there. A datacenter IP alone does not make a visit
  suspicious (VPNs and corporate proxies live there too); it is one of the
  signals used by `Plausible.Ingestion.Traffic`.

  The ranges live in `priv/datacenter_ips/ranges.txt` and are regenerated with
  `tools/datacenter_ips/generate.py`. They are loaded lazily into
  `:persistent_term` as sorted, non-overlapping integer intervals and looked up
  with a binary search.
  """

  import Bitwise

  @key {__MODULE__, :ranges}

  @spec datacenter?(String.t() | nil, map() | nil) :: boolean()
  def datacenter?(ip, ranges \\ nil)

  def datacenter?(ip, ranges) when is_binary(ip) do
    case parse(ip) do
      {family, int} -> in_ranges?(Map.fetch!(ranges || ranges(), family), int)
      nil -> false
    end
  end

  def datacenter?(_, _), do: false

  defp ranges() do
    case :persistent_term.get(@key, nil) do
      nil ->
        ranges = load(default_path())
        :persistent_term.put(@key, ranges)
        ranges

      ranges ->
        ranges
    end
  end

  defp default_path() do
    Application.app_dir(:plausible, "priv/datacenter_ips/ranges.txt")
  end

  @doc false
  def load(path) do
    lines =
      case File.read(path) do
        {:ok, content} -> String.split(content, "\n", trim: true)
        {:error, _} -> []
      end

    {v4, v6} =
      lines
      |> Enum.map(&parse_cidr/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(fn {family, _, _} -> family == :v4 end)

    %{v4: to_intervals(v4), v6: to_intervals(v6)}
  end

  defp to_intervals(ranges) do
    ranges
    |> Enum.map(fn {_family, first, last} -> {first, last} end)
    |> Enum.sort()
    |> merge([])
    |> List.to_tuple()
  end

  defp merge([], acc), do: Enum.reverse(acc)

  defp merge([{first, last} | rest], [{prev_first, prev_last} | acc_rest])
       when first <= prev_last + 1 do
    merge(rest, [{prev_first, max(last, prev_last)} | acc_rest])
  end

  defp merge([range | rest], acc), do: merge(rest, [range | acc])

  defp parse_cidr(line) do
    with [addr, bits] <- String.split(String.trim(line), "/"),
         {bits, ""} <- Integer.parse(bits),
         {family, int} <- parse(addr) do
      size = if family == :v4, do: 32, else: 128
      host_bits = size - bits
      first = int >>> host_bits <<< host_bits
      {family, first, first + (1 <<< host_bits) - 1}
    else
      _ -> nil
    end
  end

  defp parse(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}} ->
        {:v4, hi <<< 16 ||| lo}

      {:ok, {a, b, c, d}} ->
        {:v4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

      {:ok, {_, _, _, _, _, _, _, _} = groups} ->
        int =
          groups
          |> Tuple.to_list()
          |> Enum.reduce(0, fn group, acc -> acc <<< 16 ||| group end)

        {:v6, int}

      _ ->
        nil
    end
  end

  defp in_ranges?(ranges, int), do: search(ranges, int, 0, tuple_size(ranges) - 1)

  defp search(_ranges, _int, low, high) when low > high, do: false

  defp search(ranges, int, low, high) do
    mid = div(low + high, 2)
    {first, last} = elem(ranges, mid)

    cond do
      int < first -> search(ranges, int, low, mid - 1)
      int > last -> search(ranges, int, mid + 1, high)
      true -> true
    end
  end
end
