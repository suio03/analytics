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

  # Sources the app names without a host (utm_source / ?ref=), shown with that site's favicon.
  @source_domains %{
    "google" => {"Google", "google.com"},
    "bing" => {"Bing", "bing.com"},
    "chatgpt.com" => {"ChatGPT", "chatgpt.com"},
    "sunodownloader" => {"Suno Downloader", "sunodownloader.io"},
    "taaft" => {"There's An AI For That", "theresanaiforthat.com"},
    "taaft_feat" => {"There's An AI For That · featured", "theresanaiforthat.com"},
    "muzix" => {"Muzix", "muzix.app"},
    "ordalin" => {"Ordalin", "ordalin.com"},
    "ios_app" => {"iOS app", "apple.com"}
  }

  @doc "{label, favicon domain or nil, Heroicon name or nil} for a source row."
  def source_meta("(direct or unknown)"), do: {"Direct or unknown", nil, :cursor_arrow_rays}
  def source_meta("(before tracking)"), do: {"Before source tracking", nil, :clock}
  def source_meta("email"), do: {"Email", nil, :envelope}

  def source_meta(key) do
    case Map.fetch(@source_domains, key) do
      {:ok, {label, domain}} ->
        {label, domain, nil}

      :error ->
        {key, if(String.contains?(key, "."), do: key), if(!String.contains?(key, "."), do: :link)}
    end
  end

  attr(:key, :string, required: true)

  def source_label(assigns) do
    {label, domain, icon} = source_meta(assigns.key)
    assigns = assign(assigns, label: label, domain: domain, icon: icon)

    ~H"""
    <span class="flex items-center gap-3">
      <img
        :if={@domain}
        src={"/favicon/sources/#{URI.encode_www_form(@domain)}"}
        alt=""
        width="16"
        height="16"
        loading="lazy"
        class="w-4 h-4 shrink-0 rounded-sm"
      />
      <span
        :if={!@domain}
        class="w-4 h-4 shrink-0 text-gray-400 dark:text-gray-500"
        aria-hidden="true"
      >
        <Heroicons.cursor_arrow_rays :if={@icon == :cursor_arrow_rays} class="w-4 h-4" />
        <Heroicons.clock :if={@icon == :clock} class="w-4 h-4" />
        <Heroicons.envelope :if={@icon == :envelope} class="w-4 h-4" />
        <Heroicons.link :if={@icon == :link} class="w-4 h-4" />
      </span>
      <span title={@key}><%= @label %></span>
    </span>
    """
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
