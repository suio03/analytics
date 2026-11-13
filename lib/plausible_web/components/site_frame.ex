defmodule PlausibleWeb.Components.SiteFrame do
  @moduledoc "Page frame with the site section tabs (Overview, Economics, Traffic quality)."
  use Phoenix.Component

  def csrf, do: Plug.CSRFProtection.get_csrf_token()

  attr(:site, :any, required: true)
  attr(:active, :string, required: true)
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
          :for={
            {label, href, tab} <- [
              {"Economics", "/#{URI.encode_www_form(@site.domain)}/economics", "economics"},
              {"Traffic quality", "/#{URI.encode_www_form(@site.domain)}/traffic", "traffic"}
            ]
          }
          href={href}
          aria-current={if @active == tab, do: "page"}
          class={
            if @active == tab,
              do: "pb-3 border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400",
              else: "pb-3 text-gray-500 dark:text-gray-400 hover:text-indigo-600"
          }
        >
          <%= label %>
        </a>
      </nav>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
