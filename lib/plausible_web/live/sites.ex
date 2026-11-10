defmodule PlausibleWeb.Live.Sites do
  @moduledoc """
  LiveView for sites index.
  """

  use PlausibleWeb, :live_view
  use Phoenix.HTML

  import PlausibleWeb.Components.Generic
  import PlausibleWeb.Live.Components.Pagination

  alias Plausible.Auth
  alias Plausible.Site
  alias Plausible.Sites
  alias Plausible.Site.Memberships.Invitations

  # Default Scrivener page is 24; owners with many sites shouldn't have to page.
  @page_size 60

  def mount(params, _session, socket) do
    uri =
      ("/sites?" <> URI.encode_query(Map.take(params, ["filter_text"])))
      |> URI.new!()

    socket =
      socket
      |> assign(:uri, uri)
      |> assign(:filter_text, params["filter_text"] || "")

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:params, params)
      |> load_sites()
      |> assign_new(:has_sites?, fn %{current_user: current_user} ->
        Site.Memberships.any_or_pending?(current_user)
      end)
      |> assign_new(:needs_to_upgrade, fn %{current_user: current_user, sites: sites} ->
        user_owns_sites =
          Enum.any?(sites.entries, fn site ->
            List.first(site.memberships ++ site.invitations).role == :owner
          end) ||
            Auth.user_owns_sites?(current_user)

        user_owns_sites && Plausible.Billing.check_needs_to_upgrade(current_user)
      end)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.flash_messages flash={@flash} />
    <div
      x-data={"{selectedInvitation: null, invitationOpen: false, invitations: #{Enum.map(@invitations, &({&1.invitation.invitation_id, &1})) |> Enum.into(%{}) |> Jason.encode!}}"}
      x-on:keydown.escape.window="invitationOpen = false"
      id="sites-index"
      phx-hook="RestoreScroll"
      class="container pt-6"
    >
      <PlausibleWeb.Live.Components.Visitors.gradient_defs />
      <.upgrade_nag_screen :if={@needs_to_upgrade == {:needs_to_upgrade, :no_active_subscription}} />

      <div class="mt-6 pb-5 border-b border-gray-200 dark:border-gray-500 flex items-center justify-between">
        <h2 class="text-2xl font-bold leading-7 text-gray-900 dark:text-gray-100 sm:text-3xl sm:leading-9 sm:truncate flex-shrink-0">
          My Sites
        </h2>
      </div>

      <div class="border-t border-gray-200 pt-4 sm:flex sm:items-center sm:justify-between">
        <.search_form :if={@has_sites?} filter_text={@filter_text} uri={@uri} />
        <p :if={not @has_sites?} class="dark:text-gray-100">
          You don't have any sites yet.
        </p>
        <div class="mt-4 flex sm:ml-4 sm:mt-0">
          <a href={"/sites/new?flow=#{PlausibleWeb.Flows.provisioning()}"} class="button">
            + Add Website
          </a>
        </div>
      </div>

      <p
        :if={String.trim(@filter_text) != "" and @sites.entries == []}
        class="mt-4 dark:text-gray-100"
      >
        No sites found. Please search for something else.
      </p>

      <div :if={@has_sites?}>
        <ul
          id="site-grid"
          phx-hook="SiteOrder"
          data-reorderable={to_string(@reorderable?)}
          class="my-6 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-3"
        >
          <%= for site <- @sites.entries, not site.collapsed or site.entry_type == "invitation" do %>
            <.site
              :if={site.entry_type in ["pinned_site", "site"]}
              site={site}
              hourly_stats={@hourly_stats[site.domain]}
              reorderable?={@reorderable?}
            />
            <.invitation
              :if={site.entry_type == "invitation"}
              site={site}
              invitation={hd(site.invitations)}
              hourly_stats={@hourly_stats[site.domain]}
            />
          <% end %>
        </ul>

        <.collapsed_sites
          sites={Enum.filter(@sites.entries, &(&1.collapsed and &1.entry_type != "invitation"))}
          hourly_stats={@hourly_stats}
        />

        <.pagination
          :if={@sites.total_pages > 1}
          id="sites-pagination"
          uri={@uri}
          page_number={@sites.page_number}
          total_pages={@sites.total_pages}
        >
          Total of <span class="font-medium"><%= @sites.total_entries %></span> sites
        </.pagination>
        <.invitation_modal :if={Enum.any?(@sites.entries, &(&1.entry_type == "invitation"))} />
      </div>
    </div>
    """
  end

  def upgrade_nag_screen(assigns) do
    ~H"""
    <div class="rounded-md bg-yellow-100 p-4">
      <div class="flex">
        <div class="flex-shrink-0">
          <svg
            class="h-5 w-5 text-yellow-400"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 20 20"
            fill="currentColor"
            aria-hidden="true"
          >
            <path
              fill-rule="evenodd"
              d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <div class="ml-3">
          <h3 class="text-sm font-medium text-yellow-800">
            Payment required
          </h3>
          <div class="mt-2 text-sm text-yellow-700">
            <p>
              To access the sites you own, you need to subscribe to a monthly or yearly payment plan. <%= link(
                "Upgrade now →",
                to: Routes.settings_path(PlausibleWeb.Endpoint, :subscription),
                class: "text-sm font-medium text-yellow-800"
              ) %>
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :site, Plausible.Site, required: true
  attr :invitation, Plausible.Auth.Invitation, required: true
  attr :hourly_stats, :map, required: true

  def invitation(assigns) do
    ~H"""
    <li
      class="group cursor-pointer"
      id={"site-card-#{hash_domain(@site.domain)}"}
      data-domain={@site.domain}
      x-on:click={"invitationOpen = true; selectedInvitation = invitations['#{@invitation.invitation_id}']"}
    >
      <div class="col-span-1 bg-white dark:bg-gray-800 rounded-lg shadow p-4 group-hover:shadow-lg cursor-pointer">
        <div class="w-full flex items-center justify-between space-x-4">
          <.favicon domain={@site.domain} />
          <div class="flex-1 truncate -mt-px">
            <h3 class="text-gray-900 font-medium text-lg truncate dark:text-gray-100">
              <%= @site.domain %>
            </h3>
          </div>

          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
            Pending invitation
          </span>
        </div>
        <.site_stats hourly_stats={@hourly_stats} />
      </div>
    </li>
    """
  end

  attr :site, Plausible.Site, required: true
  attr :hourly_stats, :map, required: true
  attr :reorderable?, :boolean, default: false

  def site(assigns) do
    ~H"""
    <li
      class="group relative hidden"
      id={"site-card-#{hash_domain(@site.domain)}"}
      data-domain={@site.domain}
      data-sortable
      phx-mounted={JS.show()}
    >
      <.unstyled_link href={"/#{URI.encode_www_form(@site.domain)}"}>
        <div class="col-span-1 bg-white dark:bg-gray-800 rounded-lg shadow p-4 group-hover:shadow-lg cursor-pointer">
          <div class="w-full flex items-center justify-between space-x-4">
            <.favicon domain={@site.domain} />
            <div class="flex-1 -mt-px w-full">
              <h3
                class="text-gray-900 font-medium text-lg truncate dark:text-gray-100"
                style="width: calc(100% - 4rem)"
              >
                <%= @site.domain %>
              </h3>
            </div>
          </div>
          <.site_stats hourly_stats={@hourly_stats} />
        </div>
      </.unstyled_link>

      <button
        :if={@reorderable?}
        type="button"
        data-site-handle
        title="Drag to reorder (or focus and use the arrow keys)"
        aria-label={"Move #{@site.domain}"}
        class="absolute top-0 right-8 h-10 w-8 flex items-center justify-center rounded-md cursor-grab active:cursor-grabbing text-gray-400 dark:text-gray-600 hover:text-black dark:hover:text-indigo-400 sm:opacity-0 sm:group-hover:opacity-100 focus:opacity-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
      >
        <Heroicons.bars_2 class="w-4 h-4" />
      </button>

      <.ellipsis_menu site={@site} />
    </li>
    """
  end

  def ellipsis_menu(assigns) do
    ~H"""
    <.dropdown>
      <:button class="absolute top-0 right-0 h-10 w-10 rounded-md hover:cursor-pointer text-gray-400 dark:text-gray-600 hover:text-black dark:hover:text-indigo-400">
        <Heroicons.ellipsis_vertical class="absolute top-3 right-3 w-4 h-4" />
      </:button>
      <:panel class="absolute top-7 right-3 z-10 mt-2 w-40 rounded-md bg-white dark:bg-gray-900 shadow-lg ring-1 ring-black ring-opacity-5 focus:outline-none">
        <div class="py-1 text-sm" role="none">
          <.dropdown_link
            :if={List.first(@site.memberships).role != :viewer}
            href={"/#{URI.encode_www_form(@site.domain)}/settings/general"}
          >
            <Heroicons.cog_6_tooth class="mr-3 h-5 w-5" />
            <span>Settings</span>
          </.dropdown_link>

          <.dropdown_link
            href="#"
            x-on:click.prevent
            phx-click={
              JS.hide(
                transition: {"duration-300", "opacity-100", "opacity-0"},
                to: "#site-card-#{hash_domain(@site.domain)}",
                time: 300
              )
              |> JS.push("collapse")
            }
            phx-value-domain={@site.domain}
            data-collapse-site
          >
            <Heroicons.eye_slash class="mr-3 h-5 w-5" />
            <span>Collapse</span>
          </.dropdown_link>
        </div>
      </:panel>
    </.dropdown>
    """
  end

  attr :sites, :list, required: true
  attr :hourly_stats, :map, required: true

  # Collapsed sites keep a one-line chip below the grid: open the dashboard
  # from it, or show the site in the grid again.
  def collapsed_sites(assigns) do
    ~H"""
    <div :if={@sites != []} id="collapsed-sites" class="mb-6">
      <h3 class="mb-2 text-sm font-medium text-gray-500 dark:text-gray-400">
        Collapsed · <%= length(@sites) %>
      </h3>
      <ul class="flex flex-wrap gap-2">
        <li
          :for={site <- @sites}
          id={"collapsed-site-#{hash_domain(site.domain)}"}
          data-domain={site.domain}
          class="inline-flex max-w-full items-center rounded-full bg-white dark:bg-gray-800 shadow text-sm"
        >
          <.unstyled_link
            href={"/#{URI.encode_www_form(site.domain)}"}
            class="flex min-w-0 items-center gap-2 py-1.5 pl-3 pr-1 text-gray-800 dark:text-gray-200 hover:text-indigo-600 dark:hover:text-indigo-400"
          >
            <.favicon domain={site.domain} />
            <span class="truncate"><%= site.domain %></span>
            <span
              :if={is_map(@hourly_stats[site.domain])}
              class="text-xs tabular-nums text-gray-500 dark:text-gray-400"
              title="Visitors in last 24h"
            >
              <%= PlausibleWeb.StatsView.large_number_format(@hourly_stats[site.domain].visitors) %>
            </span>
          </.unstyled_link>
          <button
            type="button"
            phx-click="expand"
            phx-value-domain={site.domain}
            title="Show in the grid"
            aria-label={"Show #{site.domain} in the grid"}
            class="flex-shrink-0 rounded-full py-1.5 pl-1 pr-3 text-gray-400 hover:text-black dark:text-gray-500 dark:hover:text-indigo-400"
          >
            <Heroicons.eye class="h-4 w-4" />
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :hourly_stats, :map, required: true

  def site_stats(assigns) do
    ~H"""
    <div class="md:h-[84px] sm:h-[74px] h-24 pl-8 pr-8 pt-2">
      <div :if={@hourly_stats == :loading} class="text-center animate-pulse">
        <div class="md:h-[34px] sm:h-[30px] h-11 dark:bg-gray-700 bg-gray-100 rounded-md"></div>
        <div class="md:h-[26px] sm:h-[18px] h-6 mt-1 dark:bg-gray-700 bg-gray-100 rounded-md"></div>
      </div>
      <div
        :if={is_map(@hourly_stats)}
        class="hidden h-50px"
        phx-mounted={JS.show(transition: {"ease-in duration-500", "opacity-0", "opacity-100"})}
      >
        <span class="text-gray-600 dark:text-gray-400 text-sm truncate">
          <PlausibleWeb.Live.Components.Visitors.chart intervals={@hourly_stats.intervals} />
          <div class="flex justify-between items-center">
            <p>
              <span class="text-gray-800 dark:text-gray-200">
                <b><%= PlausibleWeb.StatsView.large_number_format(@hourly_stats.visitors) %></b>
                visitor<span :if={@hourly_stats.visitors != 1}>s</span> in last 24h
              </span>
            </p>

            <.percentage_change change={@hourly_stats.change} />
          </div>
          <.nonhuman_note
            suspicious={Map.get(@hourly_stats, :suspicious, 0)}
            bots={Map.get(@hourly_stats, :bots, 0)}
          />
        </span>
      </div>
    </div>
    """
  end

  attr :change, :integer, required: true

  def percentage_change(assigns) do
    ~H"""
    <p class="dark:text-gray-100">
      <span :if={@change == 0} class="font-semibold">〰</span>
      <span :if={@change > 0} class="font-semibold text-green-500">↑</span>
      <span :if={@change < 0} class="font-semibold text-red-400">↓</span>
      <%= abs(@change) %>%
    </p>
    """
  end

  def invitation_modal(assigns) do
    ~H"""
    <div
      x-cloak
      x-show="invitationOpen"
      class="fixed z-10 inset-0 overflow-y-auto"
      aria-labelledby="modal-title"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex items-end justify-center min-h-screen pt-4 px-4 pb-20 text-center sm:block sm:p-0">
        <div
          x-show="invitationOpen"
          x-transition:enter="transition ease-out duration-300"
          x-transition:enter-start="opacity-0"
          x-transition:enter-end="opacity-100"
          x-transition:leave="transition ease-in duration-200"
          x-transition:leave-start="opacity-100"
          x-transition:leave-end="opacity-0"
          class="fixed inset-0 bg-gray-500 dark:bg-gray-800 bg-opacity-75 dark:bg-opacity-75 transition-opacity"
          aria-hidden="true"
          x-on:click="invitationOpen = false"
        >
        </div>
        <!-- This element is to trick the browser into centering the modal contents. -->
        <span class="hidden sm:inline-block sm:align-middle sm:h-screen" aria-hidden="true">
          &#8203;
        </span>

        <div
          x-show="invitationOpen"
          x-transition:enter="transition ease-out duration-300"
          x-transition:enter-start="opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"
          x-transition:enter-end="opacity-100 translate-y-0 sm:scale-100"
          x-transition:leave="transition ease-in duration-200"
          x-transition:leave-start="opacity-100 translate-y-0 sm:scale-100"
          x-transition:leave-end="opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"
          class="inline-block align-bottom bg-white dark:bg-gray-900 rounded-lg text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:align-middle sm:max-w-lg sm:w-full"
        >
          <div class="bg-white dark:bg-gray-850 px-4 pt-5 pb-4 sm:p-6 sm:pb-4">
            <div class="hidden sm:block absolute top-0 right-0 pt-4 pr-4">
              <button
                x-on:click="invitationOpen = false"
                class="bg-white dark:bg-gray-800 rounded-md text-gray-400 dark:text-gray-500 hover:text-gray-500 dark:hover:text-gray-400 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                <span class="sr-only">Close</span>
                <Heroicons.x_mark class="h-6 w-6" />
              </button>
            </div>
            <div class="sm:flex sm:items-start">
              <div class="mx-auto flex-shrink-0 flex items-center justify-center h-12 w-12 rounded-full bg-green-100 sm:mx-0 sm:h-10 sm:w-10">
                <Heroicons.user_group class="h-6 w-6" />
              </div>
              <div class="mt-3 text-center sm:mt-0 sm:ml-4 sm:text-left">
                <h3
                  class="text-lg leading-6 font-medium text-gray-900 dark:text-gray-100"
                  id="modal-title"
                >
                  Invitation for
                  <span x-text="selectedInvitation && selectedInvitation.invitation.site.domain">
                  </span>
                </h3>
                <div class="mt-2">
                  <p class="text-sm text-gray-500 dark:text-gray-200">
                    You've been invited to the
                    <span x-text="selectedInvitation && selectedInvitation.invitation.site.domain">
                    </span>
                    analytics dashboard as <b
                      class="capitalize"
                      x-text="selectedInvitation && selectedInvitation.invitation.role"
                    >Admin</b>.
                  </p>
                  <div
                    x-show="selectedInvitation && !(selectedInvitation.exceeded_limits || selectedInvitation.no_plan) && selectedInvitation.invitation.role === 'owner'"
                    class="mt-2 text-sm text-gray-500 dark:text-gray-200"
                  >
                    If you accept the ownership transfer, you will be responsible for billing going forward.
                  </div>
                </div>
              </div>
            </div>
            <.notice
              x-show="selectedInvitation && selectedInvitation.missing_features"
              title="Missing features"
              class="mt-4 shadow-sm dark:shadow-none"
            >
              <p>
                The site uses <span x-text="selectedInvitation && selectedInvitation.missing_features"></span>,
                which your current subscription does not support. After accepting ownership of this site,
                you will not be able to access them unless you
                <.styled_link
                  class="inline-block"
                  href={Routes.billing_path(PlausibleWeb.Endpoint, :choose_plan)}
                >
                  upgrade to a suitable plan
                </.styled_link>.
              </p>
            </.notice>
            <.notice
              x-show="selectedInvitation && selectedInvitation.exceeded_limits"
              title="Exceeded limits"
              class="mt-4 shadow-sm dark:shadow-none"
            >
              <p>
                You are unable to accept the ownership of this site because doing so would exceed the
                <span x-text="selectedInvitation && selectedInvitation.exceeded_limits"></span>
                of your subscription.
                You can review your usage in the
                <.styled_link
                  class="inline-block"
                  href={Routes.settings_path(PlausibleWeb.Endpoint, :subscription)}
                >
                  account settings
                </.styled_link>.
              </p>
              <p class="mt-3">
                To become the owner of this site, you should either reduce your usage, or upgrade your subscription.
              </p>
            </.notice>
            <.notice
              x-show="selectedInvitation && selectedInvitation.no_plan"
              title="No subscription"
              class="mt-4 shadow-sm dark:shadow-none"
            >
              You are unable to accept the ownership of this site because your account does not have a subscription. To become the owner of this site, you should upgrade to a suitable plan.
            </.notice>
          </div>
          <div class="bg-gray-50 dark:bg-gray-850 px-4 py-3 sm:px-6 sm:flex sm:flex-row-reverse">
            <.button
              x-show="selectedInvitation && !(selectedInvitation.exceeded_limits || selectedInvitation.no_plan)"
              class="sm:ml-3 w-full sm:w-auto sm:text-sm"
              data-method="post"
              data-csrf={Plug.CSRFProtection.get_csrf_token()}
              x-bind:data-to="selectedInvitation && ('/sites/invitations/' + selectedInvitation.invitation.invitation_id + '/accept')"
            >
              Accept &amp; Continue
            </.button>
            <.button_link
              x-show="selectedInvitation && (selectedInvitation.exceeded_limits || selectedInvitation.no_plan)"
              href={Routes.billing_path(PlausibleWeb.Endpoint, :choose_plan)}
              class="sm:ml-3 w-full sm:w-auto sm:text-sm"
            >
              Upgrade
            </.button_link>
            <button
              type="button"
              class="mt-3 w-full inline-flex justify-center rounded-md border border-gray-300 dark:border-gray-500 shadow-sm px-4 py-2 bg-white dark:bg-gray-800 text-base font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-850 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 sm:mt-0 sm:ml-3 sm:w-auto sm:text-sm"
              data-method="post"
              data-csrf={Plug.CSRFProtection.get_csrf_token()}
              x-bind:data-to="selectedInvitation && ('/sites/invitations/' + selectedInvitation.invitation.invitation_id + '/reject')"
            >
              Reject
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :filter_text, :string, default: ""
  attr :uri, URI, required: true

  def search_form(assigns) do
    ~H"""
    <form id="filter-form" phx-change="filter" action={@uri} method="GET">
      <div class="text-gray-800 text-sm inline-flex items-center">
        <div class="relative rounded-md flex">
          <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3">
            <Heroicons.magnifying_glass class="feather mr-1 dark:text-gray-300" />
          </div>
          <input
            type="text"
            name="filter_text"
            id="filter-text"
            phx-debounce={200}
            class="pl-8 dark:bg-gray-900 dark:text-gray-300 focus:ring-indigo-500 focus:border-indigo-500 block w-full sm:text-sm border-gray-300 dark:border-gray-500 rounded-md dark:bg-gray-800"
            placeholder="Press / to search sites"
            autocomplete="off"
            value={@filter_text}
            x-ref="filter_text"
            x-on:keydown.escape="$refs.filter_text.blur(); $refs.reset_filter?.dispatchEvent(new Event('click', {bubbles: true, cancelable: true}));"
            x-on:keydown.prevent.slash.window="$refs.filter_text.focus(); $refs.filter_text.select();"
            x-on:blur="$refs.filter_text.placeholder = 'Press / to search sites';"
            x-on:focus="$refs.filter_text.placeholder = 'Search sites';"
          />
        </div>

        <button
          :if={String.trim(@filter_text) != ""}
          class="phx-change-loading:hidden ml-2"
          phx-click="reset-filter-text"
          id="reset-filter"
          x-ref="reset_filter"
          type="button"
        >
          <Heroicons.backspace class="feather hover:text-red-500 dark:text-gray-300 dark:hover:text-red-500" />
        </button>

        <.spinner class="hidden phx-change-loading:inline ml-2" />
      </div>
    </form>
    """
  end

  def favicon(assigns) do
    src = "/favicon/sources/#{URI.encode_www_form(assigns.domain)}?v=2"
    assigns = assign(assigns, :src, src)

    ~H"""
    <span class="w-4 h-4 flex-shrink-0 mt-px rounded bg-gray-100 inline-flex items-center justify-center">
      <img
        src={@src}
        alt=""
        onerror="this.onerror=null; this.src='/favicon/sources/placeholder?v=2';"
        class="w-4 h-4 rounded object-contain"
      />
    </span>
    """
  end

  def handle_event(event, %{"domain" => domain}, socket) when event in ["collapse", "expand"] do
    case Enum.find(socket.assigns.sites.entries, &(&1.domain == domain)) do
      %Site{entry_type: type} = site when type != "invitation" ->
        Sites.set_collapsed(socket.assigns.current_user, site, event == "collapse")
        {:noreply, load_sites(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder", %{"domains" => domains}, socket) when is_list(domains) do
    if socket.assigns.reorderable? do
      Sites.reorder(socket.assigns.current_user, domains)
      {:noreply, load_sites(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "filter",
        %{"filter_text" => filter_text},
        %{assigns: %{filter_text: filter_text}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("filter", %{"filter_text" => filter_text}, socket) do
    socket =
      socket
      |> reset_pagination()
      |> set_filter_text(filter_text)

    {:noreply, socket}
  end

  def handle_event("reset-filter-text", _params, socket) do
    socket =
      socket
      |> reset_pagination()
      |> set_filter_text("")

    {:noreply, socket}
  end

  attr :suspicious, :integer, required: true
  attr :bots, :integer, required: true

  # Same wording and colors as the visitors subline on the dashboard
  # (assets/js/dashboard/stats/graph/top-stats.js). The visitors count above
  # already leaves this traffic out.
  defp nonhuman_note(assigns) do
    ~H"""
    <p
      :if={@suspicious > 0 or @bots > 0}
      class="text-xs whitespace-nowrap"
      data-test-id="nonhuman-note"
    >
      <span :if={@suspicious > 0} class="text-amber-600 dark:text-amber-400">
        +<%= PlausibleWeb.StatsView.large_number_format(@suspicious) %> suspicious
      </span>
      <span :if={@suspicious > 0 and @bots > 0} class="text-gray-400">·</span>
      <span :if={@bots > 0} class="text-red-500 dark:text-red-400">
        +<%= PlausibleWeb.StatsView.large_number_format(@bots) %> bot<%= if @bots != 1, do: "s" %>
      </span>
    </p>
    """
  end

  defp load_sites(%{assigns: assigns} = socket) do
    sites =
      Sites.list_with_invitations(
        assigns.current_user,
        Map.put_new(assigns.params, "page_size", @page_size),
        filter_by_domain: assigns.filter_text
      )

    hourly_stats =
      if connected?(socket) do
        Plausible.Stats.Clickhouse.last_24h_visitors_hourly_intervals(sites.entries)
      else
        sites.entries
        |> Enum.into(%{}, fn site ->
          {site.domain, :loading}
        end)
      end

    invitations = extract_invitations(sites.entries, assigns.current_user)

    assign(
      socket,
      sites: sites,
      invitations: invitations,
      hourly_stats: hourly_stats,
      # The stored order covers all sites, so dragging only makes sense when
      # all of them are on screen.
      reorderable?: String.trim(assigns.filter_text) == "" and sites.total_pages <= 1
    )
  end

  defp extract_invitations(sites, user) do
    sites
    |> Enum.filter(&(&1.entry_type == "invitation"))
    |> Enum.flat_map(& &1.invitations)
    |> Enum.map(&check_limits(&1, user))
  end

  defp check_limits(%{role: :owner, site: site} = invitation, user) do
    case Invitations.ensure_can_take_ownership(site, user) do
      :ok ->
        check_features(invitation, user)

      {:error, :no_plan} ->
        %{invitation: invitation, no_plan: true}

      {:error, {:over_plan_limits, limits}} ->
        limits = PlausibleWeb.TextHelpers.pretty_list(limits)
        %{invitation: invitation, exceeded_limits: limits}
    end
  end

  defp check_limits(invitation, _), do: %{invitation: invitation}

  defp check_features(%{role: :owner, site: site} = invitation, user) do
    case Invitations.check_feature_access(site, user, ce?()) do
      :ok ->
        %{invitation: invitation}

      {:error, {:missing_features, features}} ->
        feature_names =
          features
          |> Enum.map(& &1.display_name())
          |> PlausibleWeb.TextHelpers.pretty_list()

        %{invitation: invitation, missing_features: feature_names}
    end
  end

  defp set_filter_text(socket, filter_text) do
    uri = socket.assigns.uri

    uri_params =
      uri.query
      |> URI.decode_query()
      |> Map.put("filter_text", filter_text)
      |> URI.encode_query()

    uri = %{uri | query: uri_params}

    socket
    |> assign(:filter_text, filter_text)
    |> assign(:uri, uri)
    |> push_patch(to: URI.to_string(uri), replace: true)
  end

  defp reset_pagination(socket) do
    pagination_fields = ["page"]
    uri = socket.assigns.uri

    uri_params =
      uri.query
      |> URI.decode_query()
      |> Map.drop(pagination_fields)
      |> URI.encode_query()

    assign(socket,
      uri: %{uri | query: uri_params},
      params: Map.drop(socket.assigns.params, pagination_fields)
    )
  end

  defp hash_domain(domain) do
    :sha |> :crypto.hash(domain) |> Base.encode16()
  end
end
