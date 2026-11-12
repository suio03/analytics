defmodule Plausible.Ingestion.Network do
  @moduledoc """
  Hashes the network a visitor comes from: the /24 of an IPv4 address or the
  /48 of an IPv6 address.

  The hash uses the same daily rotating salt as the visitor id, so networks
  can be compared within one UTC day and the address itself is never stored.
  `Plausible.Workers.TrafficFarms` uses it to find one network sending many
  single-page visitors who never come back (a "visitor farm").
  """

  import Bitwise

  @spec hash(String.t() | nil, binary() | nil) :: non_neg_integer()
  def hash(ip, salt) when is_binary(ip) and is_binary(salt) do
    case prefix(ip) do
      nil -> 0
      prefix -> SipHash.hash!(salt, "net:" <> prefix)
    end
  end

  def hash(_ip, _salt), do: 0

  @doc "Returns the /24 (IPv4) or /48 (IPv6) network of an address as a string."
  @spec prefix(String.t()) :: String.t() | nil
  def prefix(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, low}} ->
        v4_prefix({high >>> 8, high &&& 0xFF, low >>> 8})

      {:ok, {a, b, c, _d}} ->
        v4_prefix({a, b, c})

      {:ok, {a, b, c, _, _, _, _, _}} ->
        Enum.map_join([a, b, c], ":", &Integer.to_string(&1, 16)) <> "::/48"

      {:error, _} ->
        nil
    end
  end

  defp v4_prefix({a, b, c}), do: "#{a}.#{b}.#{c}.0/24"
end
