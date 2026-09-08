defmodule Plausible.Payments.SignatureTest do
  use ExUnit.Case, async: true
  alias Plausible.Payments.Signature
  defp mac(value), do: :crypto.mac(:hmac, :sha256, "secret", value) |> Base.encode16(case: :lower)

  test "Paddle verifies exact bytes, timestamps and rotated signatures" do
    body = ~s({"id":"evt_1"})
    header = "ts=100;h1=invalid;h1=#{mac("100:" <> body)}"
    assert Signature.valid?("paddle", "secret", body, header, 102)
    refute Signature.valid?("paddle", "secret", body <> " ", header, 102)
    refute Signature.valid?("paddle", "secret", body, header, 106)
    refute Signature.valid?("paddle", "secret", body, "bad", 100)
    refute Signature.valid?("paddle", "secret", body, nil, 100)
  end

  test "Creem verifies exact bytes and rejects missing signatures" do
    body = ~s({"eventType":"checkout.completed"})
    assert Signature.valid?("creem", "secret", body, mac(body))
    refute Signature.valid?("creem", "wrong", body, mac(body))
    refute Signature.valid?("creem", "secret", body, nil)
  end
end
