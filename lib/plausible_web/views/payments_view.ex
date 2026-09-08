defmodule PlausibleWeb.PaymentsView do
  use PlausibleWeb, :view

  def path(site, suffix \\ ""), do: "/#{URI.encode_www_form(site.domain)}/transactions#{suffix}"

  def query_path(site, filters, page),
    do: path(site) <> "?" <> URI.encode_query(Map.put(filters, "page", page))

  def csrf, do: Plug.CSRFProtection.get_csrf_token()

  def money(nil, _), do: "—"

  def money(amount, currency) do
    case Money.new(currency, 0) do
      %Money{} -> Money.from_integer(amount, currency) |> Money.to_string!()
      _ -> "#{currency} #{amount} minor units"
    end
  end

  def timestamp(nil, _), do: "—"

  def timestamp(datetime, site),
    do: datetime |> DateTime.shift_zone!(site.timezone) |> Calendar.strftime("%b %-d, %Y · %H:%M")

  def value(nil), do: "—"
  def value(""), do: "—"
  def value(value), do: value
  def product_name(t), do: Enum.map_join(t.items, ", ", &(&1["name"] || &1["id"] || "Product"))
  def display_label(value), do: value |> String.replace("_", " ") |> String.capitalize()
  def provider_name("paddle"), do: "Paddle"
  def provider_name("creem"), do: "Creem"

  def method(t) do
    [t.details["card_brand"] || t.details["payment_method"], t.details["card_last4"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> value()
  end

  def dashboard_url(%{provider: "paddle", environment: env}, external_id),
    do:
      "https://#{if env == "sandbox", do: "sandbox-", else: ""}vendors.paddle.com/transactions-v2/#{URI.encode_www_form(external_id)}"

  def dashboard_url(%{provider: "creem"}, _), do: "https://www.creem.io/dashboard"

  attr(:site, :any, required: true)
  attr(:active, :string, default: "transactions")
  slot(:inner_block, required: true)

  def frame(assigns) do
    ~H"""
    <div class="max-w-screen-xl mx-auto px-4 sm:px-6 py-8 text-gray-900 dark:text-gray-100">
      <div class="text-sm text-gray-500 dark:text-gray-400 mb-4"><%= @site.domain %></div>
      <nav
        aria-label="Site sections"
        class="flex gap-6 mb-8 text-sm font-medium border-b border-gray-200 dark:border-gray-700"
      >
        <a
          href={"/#{URI.encode_www_form(@site.domain)}"}
          class="pb-3 text-gray-500 dark:text-gray-400 hover:text-indigo-600"
        >
          Overview
        </a>
        <a
          href={path(@site)}
          aria-current={if @active == "transactions", do: "page"}
          class="pb-3 border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400"
        >
          Transactions
        </a>
      </nav>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr(:status, :string, required: true)

  def status_badge(assigns) do
    color =
      case assigns.status do
        "paid" ->
          "bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200"

        "incomplete" ->
          "bg-indigo-100 text-indigo-700 dark:bg-indigo-900 dark:text-indigo-200"

        s when s in ["failed", "disputed"] ->
          "bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-200"

        _ ->
          "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-200"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium whitespace-nowrap",
      @color
    ]}>
      <span aria-hidden="true"><%= if @status == "paid", do: "✓", else: "•" %></span>
      <%= display_label(@status) %>
    </span>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: "")
  attr(:options, :list, required: true)

  def filter_select(assigns) do
    ~H"""
    <label class="block text-xs font-medium text-gray-500 dark:text-gray-400">
      <%= @label %>
      <select
        name={@name}
        class="mt-1 block w-full rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-800 text-sm text-gray-900 dark:text-gray-100"
      >
        <option
          :for={{label, val} <- @options}
          value={val}
          selected={to_string(@value) == to_string(val)}
        >
          <%= label %>
        </option>
      </select>
    </label>
    """
  end
end
