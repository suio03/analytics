defmodule PlausibleWeb.EconomicsView do
  use PlausibleWeb, :view

  defdelegate frame(assigns), to: PlausibleWeb.PaymentsView
  defdelegate csrf(), to: PlausibleWeb.PaymentsView

  def path(site, suffix \\ ""), do: "/#{URI.encode_www_form(site.domain)}/economics#{suffix}"

  def usd(nil), do: "—"
  def usd(n) when n == 0, do: "$0"
  def usd(n) when abs(n) < 1, do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  def usd(n) when abs(n) < 100, do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  def usd(n), do: "$" <> Integer.to_string(round(n))

  def per(nil), do: "—"
  def per(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  def pct(nil), do: "—"
  def pct(n), do: "#{round(n * 100)}%"

  def times(nil), do: "—"
  def times(n) when n >= 10, do: "#{round(n)}×"
  def times(n), do: :erlang.float_to_binary(n / 1, decimals: 1) <> "×"

  def generated(iso, site) do
    case DateTime.from_iso8601(if is_binary(iso), do: iso, else: "") do
      {:ok, dt, _} ->
        dt |> DateTime.shift_zone!(site.timezone) |> Calendar.strftime("%b %-d · %H:%M")

      _ ->
        "—"
    end
  end

  @doc "Red below 1×, amber below 3×; a young cohort (still filling) is not colored."
  def payback_class(nil, _), do: "text-gray-400"
  def payback_class(_, false), do: "text-gray-500"
  def payback_class(n, true) when n < 1, do: "text-red-600 dark:text-red-400 font-semibold"
  def payback_class(n, true) when n < 3, do: "text-amber-600 dark:text-amber-400 font-semibold"
  def payback_class(_, true), do: "text-emerald-600 dark:text-emerald-400 font-semibold"

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, default: nil)

  def stat(assigns) do
    ~H"""
    <div class="p-5">
      <p class="text-xs text-gray-500 dark:text-gray-400"><%= @label %></p>
      <p class="mt-2 text-2xl font-semibold tabular-nums"><%= @value %></p>
      <p :if={@note} class="mt-2 text-xs text-gray-500"><%= @note %></p>
    </div>
    """
  end
end
