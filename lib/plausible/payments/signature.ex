defmodule Plausible.Payments.Signature do
  @moduledoc "Verifies the exact bytes received from payment providers."

  def valid?(provider, secret, body, header, now \\ System.system_time(:second))

  def valid?("paddle", secret, body, header, now) when is_binary(header) and is_binary(body) do
    parts = header |> String.split(";") |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    with [_, timestamp] <- Enum.find(parts, &(List.first(&1) == "ts")),
         {seconds, ""} <- Integer.parse(timestamp),
         true <- abs(now - seconds) <= 5 do
      digest = mac(secret, timestamp <> ":" <> body)

      Enum.any?(parts, fn
        ["h1", value] -> secure_equal?(digest, value)
        _ -> false
      end)
    else
      _ -> false
    end
  end

  def valid?("creem", secret, body, header, _) when is_binary(header) and is_binary(body),
    do: secure_equal?(mac(secret, body), header)

  def valid?(_, _, _, _, _), do: false

  defp mac(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

  defp secure_equal?(a, b), do: byte_size(a) == byte_size(b) && Plug.Crypto.secure_compare(a, b)
end
