defmodule Plausible.Ingestion.NetworkTest do
  use ExUnit.Case, async: true

  alias Plausible.Ingestion.Network

  test "prefix is the /24 for IPv4 and the /48 for IPv6" do
    assert Network.prefix("81.2.69.142") == "81.2.69.0/24"
    assert Network.prefix("::ffff:81.2.69.142") == "81.2.69.0/24"
    assert Network.prefix("2001:db8:abcd:12::1") == "2001:DB8:ABCD::/48"
    assert Network.prefix("not an ip") == nil
  end

  test "addresses in one network share a hash for one salt" do
    salt = :crypto.strong_rand_bytes(16)
    other_salt = :crypto.strong_rand_bytes(16)

    assert Network.hash("81.2.69.1", salt) == Network.hash("81.2.69.254", salt)
    refute Network.hash("81.2.69.1", salt) == Network.hash("81.2.70.1", salt)
    refute Network.hash("81.2.69.1", salt) == Network.hash("81.2.69.1", other_salt)
    assert Network.hash(nil, salt) == 0
    assert Network.hash("81.2.69.1", nil) == 0
  end
end
