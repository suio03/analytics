defmodule PlausibleWeb.EconomicsView do
  use PlausibleWeb, :view

  defdelegate frame(assigns), to: PlausibleWeb.Components.SiteFrame
  defdelegate csrf(), to: PlausibleWeb.Components.SiteFrame

  def path(site, suffix \\ ""), do: "/#{URI.encode_www_form(site.domain)}/economics#{suffix}"

  def usd(nil), do: "—"
  def usd(n) when n == 0, do: "$0"
  def usd(n) when n < 0, do: "-" <> usd(-n)
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

  def generated(iso, tz) do
    case DateTime.from_iso8601(if is_binary(iso), do: iso, else: "") do
      {:ok, dt, _} ->
        dt |> DateTime.shift_zone!(tz || "Etc/UTC") |> Calendar.strftime("%b %-d · %H:%M")

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

  @doc "Plan, or the last thing bought, and the platform the account was made on."
  def payer_plan(r) do
    what = sku_label(r["plan"] || r["lastSku"])
    platform = %{"ios" => "iOS", "android" => "Android", "web" => "Web"}[r["platform"]]
    [what, platform] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  # creator_monthly → Creator monthly, pack_240 → 240 credits, gift_song_video → Gift song video
  defp sku_label(nil), do: nil

  defp sku_label("pack_" <> n), do: "#{n} credits"

  defp sku_label(sku) do
    sku |> String.replace("_", " ") |> String.capitalize()
  end

  def short_date(nil, _), do: "—"

  def short_date(unix, tz) when is_number(unix) do
    unix
    |> trunc()
    |> DateTime.from_unix!()
    |> DateTime.shift_zone!(tz || "Etc/UTC")
    |> Calendar.strftime("%b %-d")
  end

  attr(:code, :string, default: nil)
  attr(:from, :string, default: nil)

  @doc "Flag and name of an ISO country code; the tooltip says where it came from."
  def country(assigns) do
    c = assigns.code && Location.Country.get_country(assigns.code)
    assigns = assign(assigns, c: c)

    ~H"""
    <span :if={!@code} class="text-gray-400">—</span>
    <span :if={@code} title={if @from, do: "#{@code} · from #{@from}", else: @code}>
      <%= if @c, do: "#{@c.flag} #{@c.name}", else: @code %>
    </span>
    """
  end

  @doc "Short name of an IANA zone for labels: Australia/Melbourne → Melbourne, Etc/UTC → UTC."
  def tz_label(tz) when is_binary(tz) do
    tz |> String.split("/") |> List.last() |> String.replace("_", " ")
  end

  def tz_label(_), do: "UTC"

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:collapsed, :boolean, default: false, doc: "Collapsed until the viewer opens it")
  slot(:inner_block, required: true)

  @doc """
  A report section: a handle that drags it (or moves it with the arrow keys) and a title that
  collapses it. `reorder_script/1` restores the viewer's order and open/closed state.
  """
  def section(assigns) do
    ~H"""
    <section data-economics-section={@id} data-collapsed-default={to_string(@collapsed)} class="mb-10">
      <div class="flex items-center gap-2 mb-1">
        <button
          type="button"
          data-economics-handle
          title="Drag to reorder (or focus and use the arrow keys)"
          aria-label={"Move #{@title}"}
          class="-ml-1 p-1 rounded cursor-grab active:cursor-grabbing text-gray-300 hover:text-gray-500 dark:text-gray-600 dark:hover:text-gray-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
        >
          <Heroicons.bars_2 class="w-4 h-4" />
        </button>
        <h2 class="text-lg font-semibold">
          <button
            type="button"
            data-economics-toggle
            aria-expanded={to_string(!@collapsed)}
            aria-controls={"economics-#{@id}"}
            class="group flex items-center gap-1.5 rounded hover:text-indigo-600 dark:hover:text-indigo-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500"
          >
            <%= @title %>
            <Heroicons.chevron_down
              data-economics-chevron
              class={[
                "w-4 h-4 text-gray-400 transition-transform group-hover:text-indigo-500",
                @collapsed && "-rotate-90"
              ]}
            />
          </button>
        </h2>
      </div>
      <div id={"economics-#{@id}"} data-economics-body class={[@collapsed && "hidden"]}>
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  @doc """
  Restores the viewer's section order and which sections are collapsed (kept in this browser, the
  same on every site), lets them drag sections by their handle or move a focused handle with the
  arrow keys, collapse a section from its title, and show the sources folded into "Other".
  """
  def reorder_script(assigns) do
    ~H"""
    <script>
      (function () {
        var KEY = "economics-section-order-v2";
        var COLLAPSED = "economics-collapsed";
        var box = document.querySelector("[data-economics-sections]");
        if (!box) return;
        function sections() {
          return Array.prototype.filter.call(box.children, function (el) {
            return el.hasAttribute("data-economics-section");
          });
        }
        function idOf(el) { return el.getAttribute("data-economics-section"); }
        function save() {
          try { localStorage.setItem(KEY, JSON.stringify(sections().map(idOf))); } catch (e) {}
        }
        try {
          var saved = JSON.parse(localStorage.getItem(KEY) || "[]");
          if (Array.isArray(saved)) {
            var all = sections();
            // A section newer than the saved order goes right after the one before it on the page.
            var rank = function (el) {
              var i = saved.indexOf(idOf(el));
              if (i >= 0) return i;
              var at = all.indexOf(el);
              for (var p = at - 1; p >= 0; p--) {
                var j = saved.indexOf(idOf(all[p]));
                if (j >= 0) return j + 0.5 + at / 1000;
              }
              return at / 1000 - 1;
            };
            all.slice().sort(function (a, b) { return rank(a) - rank(b); }).forEach(function (el) { box.appendChild(el); });
          }
        } catch (e) {}

        var collapsed = {};
        try {
          var c = JSON.parse(localStorage.getItem(COLLAPSED) || "{}");
          if (c && typeof c === "object" && !Array.isArray(c)) collapsed = c;
        } catch (e) {}
        function setCollapsed(el, closed) {
          var body = el.querySelector("[data-economics-body]");
          var toggle = el.querySelector("[data-economics-toggle]");
          var chevron = el.querySelector("[data-economics-chevron]");
          body.classList.toggle("hidden", closed);
          toggle.setAttribute("aria-expanded", closed ? "false" : "true");
          if (chevron) chevron.classList.toggle("-rotate-90", closed);
        }
        sections().forEach(function (el) {
          if (typeof collapsed[idOf(el)] === "boolean") setCollapsed(el, collapsed[idOf(el)]);
        });
        box.addEventListener("click", function (e) {
          var more = e.target.closest("[data-economics-more]");
          if (more) {
            var table = more.closest("tbody");
            table.querySelectorAll("[data-economics-minor]").forEach(function (r) { r.classList.remove("hidden"); });
            more.closest("tr").remove();
            return;
          }
          var toggle = e.target.closest("[data-economics-toggle]");
          if (!toggle) return;
          var el = toggle.closest("[data-economics-section]");
          var closed = toggle.getAttribute("aria-expanded") === "true";
          setCollapsed(el, closed);
          var fallback = el.getAttribute("data-collapsed-default") === "true";
          if (closed === fallback) delete collapsed[idOf(el)]; else collapsed[idOf(el)] = closed;
          try { localStorage.setItem(COLLAPSED, JSON.stringify(collapsed)); } catch (e) {}
        });

        var dragging = null;
        box.addEventListener("pointerdown", function (e) {
          var handle = e.target.closest("[data-economics-handle]");
          if (handle) handle.closest("[data-economics-section]").draggable = true;
        });
        box.addEventListener("pointerup", function () {
          sections().forEach(function (el) { el.draggable = false; });
        });
        box.addEventListener("dragstart", function (e) {
          dragging = e.target.closest("[data-economics-section]");
          if (!dragging) return;
          e.dataTransfer.effectAllowed = "move";
          e.dataTransfer.setData("text/plain", idOf(dragging));
          dragging.classList.add("opacity-50");
        });
        box.addEventListener("dragover", function (e) {
          if (!dragging) return;
          e.preventDefault();
          var before = sections().find(function (el) {
            var r = el.getBoundingClientRect();
            return el !== dragging && e.clientY < r.top + r.height / 2;
          });
          if (before) { if (dragging.nextElementSibling !== before) box.insertBefore(dragging, before); }
          else if (box.lastElementChild !== dragging) box.appendChild(dragging);
        });
        box.addEventListener("drop", function (e) { if (dragging) e.preventDefault(); });
        box.addEventListener("dragend", function () {
          if (!dragging) return;
          dragging.classList.remove("opacity-50");
          dragging.draggable = false;
          dragging = null;
          save();
        });
        box.addEventListener("keydown", function (e) {
          var handle = e.target.closest("[data-economics-handle]");
          if (!handle || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
          e.preventDefault();
          var el = handle.closest("[data-economics-section]");
          if (e.key === "ArrowUp" && el.previousElementSibling) box.insertBefore(el, el.previousElementSibling);
          if (e.key === "ArrowDown" && el.nextElementSibling) box.insertBefore(el.nextElementSibling, el);
          handle.focus();
          el.scrollIntoView({ block: "nearest" });
          save();
        });
      })();
    </script>
    """
  end

  attr(:usage, :map, required: true)

  @doc """
  The "Model cost" section: what free and paying users cost over the days the viewer picks (today,
  yesterday, the last 7 or 28 days, the page's whole window, or any two dates inside it), with a
  bar per day and what the cost was spent on. The report's per-day rows are embedded as JSON and
  summed in the browser, so changing the period doesn't ask the app again.
  """
  def usage(assigns) do
    assigns =
      assign(assigns,
        json: Jason.encode!(assigns.usage, escape: :html_safe),
        count: length(assigns.usage["days"])
      )

    ~H"""
    <div data-economics-usage>
      <div class="mb-3 flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
        <span class="flex gap-3">
          <button
            :for={
              {key, label} <- [
                {"today", "Today"},
                {"yesterday", "Yesterday"},
                {"7", "7 days"},
                {"28", "28 days"},
                {"all", "All #{@count} days"}
              ]
            }
            type="button"
            data-usage-preset={key}
            aria-pressed="false"
            class="text-gray-500 hover:text-indigo-600 dark:hover:text-indigo-400"
          >
            <%= label %>
          </button>
        </span>
        <span class="flex items-center gap-2 text-gray-500">
          <input
            type="date"
            data-usage-from
            aria-label="From (UTC day)"
            class="rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-800 py-1 px-2 text-sm"
          /> to
          <input
            type="date"
            data-usage-to
            aria-label="To (UTC day)"
            class="rounded-md border-gray-300 dark:border-gray-600 dark:bg-gray-800 py-1 px-2 text-sm"
          />
        </span>
      </div>
      <div data-usage-out></div>
      <p class="mt-3 text-xs text-gray-500 dark:text-gray-400">
        UTC days. A cost counts as a paying user's from that account's first paid order on; before it, as a free user's. To go further back, widen the page's window at the top.
      </p>
    </div>
    <script type="application/json" id="economics-usage-data">
      <%= Phoenix.HTML.raw(@json) %>
    </script>
    <script>
      (function () {
        var root = document.querySelector("[data-economics-usage]");
        var src = document.getElementById("economics-usage-data");
        if (!root || !src) return;
        var data;
        try { data = JSON.parse(src.textContent); } catch (e) { return; }
        var days = data.days, kinds = data.kinds, rows = data.rows, last = days.length - 1;
        var from = root.querySelector("[data-usage-from]");
        var to = root.querySelector("[data-usage-to]");
        var out = root.querySelector("[data-usage-out]");
        var FREE = "#f59e0b", PAID = "#6366f1";

        function esc(s) {
          return String(s).replace(/[&<>"']/g, function (c) {
            return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
          });
        }
        function usd(n) {
          if (!n) return "$0";
          return "$" + (n >= 100 ? Math.round(n).toLocaleString("en-US") : n.toFixed(2));
        }
        function count(n, one, many) { return n + " " + (n === 1 ? one : many); }
        function shortDay(iso) {
          var d = new Date(iso + "T00:00:00Z");
          return d.toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
        }

        function compute(a, b) {
          var r = { free: 0, paid: 0, freeUsers: {}, paidUsers: {}, kinds: kinds.map(function () { return [0, 0]; }), days: [] };
          for (var d = a; d <= b; d++) r.days.push([0, 0]);
          rows.forEach(function (x) {
            if (x[0] < a || x[0] > b) return;
            r.free += x[3]; r.paid += x[4];
            r.kinds[x[2]][0] += x[3]; r.kinds[x[2]][1] += x[4];
            r.days[x[0] - a][0] += x[3]; r.days[x[0] - a][1] += x[4];
            if (x[1] >= 0 && x[3] > 0) r.freeUsers[x[1]] = 1;
            if (x[1] >= 0 && x[4] > 0) r.paidUsers[x[1]] = 1;
          });
          r.freeUsers = Object.keys(r.freeUsers).length;
          r.paidUsers = Object.keys(r.paidUsers).length;
          return r;
        }

        function tile(label, color, value, note) {
          return '<div class="p-5"><p class="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">' +
            (color ? '<span class="w-2 h-2 rounded-full" style="background:' + color + '"></span>' : "") + label + "</p>" +
            '<p class="mt-2 text-2xl font-semibold tabular-nums">' + value + "</p>" +
            '<p class="mt-2 text-xs text-gray-500 tabular-nums">' + note + "</p></div>";
        }
        function perUser(usd_, n) {
          return n ? count(n, "account", "accounts") + " · " + usd(usd_ / n) + " each" : "No accounts";
        }

        function render(a, b) {
          var r = compute(a, b), total = r.free + r.paid, n = b - a + 1;
          var html = '<div class="grid grid-cols-1 sm:grid-cols-3 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 divide-y sm:divide-y-0 sm:divide-x divide-gray-100 dark:divide-gray-700">' +
            tile("Free users", FREE, usd(r.free), perUser(r.free, r.freeUsers)) +
            tile("Paying users", PAID, usd(r.paid), perUser(r.paid, r.paidUsers)) +
            tile("Total", null, usd(total), n > 1 ? usd(total / n) + " a day over " + n + " days" : (total ? Math.round((r.free / total) * 100) + "% from free users" : "No model cost")) +
            "</div>";

          if (n > 1) {
            var top = Math.max.apply(null, r.days.map(function (d) { return d[0] + d[1]; })) || 1;
            html += '<div class="mt-4 p-5 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800">' +
              '<div class="flex items-end gap-px h-28">' +
              r.days.map(function (d, i) {
                var day = days[a + i];
                return '<div class="flex-1 h-full flex flex-col justify-end" title="' + esc(shortDay(day) + (a + i === last ? " (so far)" : "") + " · free " + usd(d[0]) + " · paying " + usd(d[1])) + '">' +
                  '<div style="height:' + ((d[1] / top) * 100).toFixed(1) + "%;background:" + PAID + '"></div>' +
                  '<div style="height:' + ((d[0] / top) * 100).toFixed(1) + "%;background:" + FREE + '"></div></div>';
              }).join("") + "</div>" +
              '<div class="mt-2 flex justify-between text-xs text-gray-500 tabular-nums"><span>' + shortDay(days[a]) + "</span><span>Highest day " + usd(top) + "</span><span>" + shortDay(days[b]) + (b === last ? " · so far" : "") + "</span></div></div>";
          }

          var order = kinds.map(function (k, i) { return i; }).filter(function (i) { return r.kinds[i][0] + r.kinds[i][1] > 0; })
            .sort(function (x, y) { return r.kinds[y][0] + r.kinds[y][1] - (r.kinds[x][0] + r.kinds[x][1]); });
          if (data.labelled && order.length) {
            html += '<div class="mt-4 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-x-auto">' +
              '<table class="w-full text-sm text-left tabular-nums"><thead class="bg-gray-50 dark:bg-gray-850 text-xs text-gray-500 dark:text-gray-400"><tr>' +
              '<th class="px-5 py-3">Spent on</th><th class="px-4 py-3 text-right">Free users</th><th class="px-4 py-3 text-right">Paying users</th><th class="px-4 py-3 text-right">Total</th><th class="px-4 py-3 text-right">Share</th></tr></thead>' +
              '<tbody class="divide-y divide-gray-100 dark:divide-gray-700">' +
              order.map(function (i) {
                var k = r.kinds[i], sum = k[0] + k[1];
                return '<tr><td class="px-5 py-3 font-medium">' + esc(kinds[i]) + '</td><td class="px-4 py-3 text-right">' + usd(k[0]) +
                  '</td><td class="px-4 py-3 text-right">' + usd(k[1]) + '</td><td class="px-4 py-3 text-right">' + usd(sum) +
                  '</td><td class="px-4 py-3 text-right text-gray-500">' + Math.round((sum / total) * 100) + "%</td></tr>";
              }).join("") + "</tbody></table></div>";
          }
          out.innerHTML = html;
        }

        function clamp(i) { return Math.min(Math.max(i, 0), last); }
        function apply(a, b, preset) {
          a = clamp(a); b = clamp(b);
          if (a > b) { var t = a; a = b; b = t; }
          from.value = days[a]; to.value = days[b];
          root.querySelectorAll("[data-usage-preset]").forEach(function (el) {
            var on = el.getAttribute("data-usage-preset") === preset;
            el.setAttribute("aria-pressed", on ? "true" : "false");
            el.classList.toggle("font-semibold", on);
            el.classList.toggle("text-indigo-600", on);
            el.classList.toggle("text-gray-500", !on);
          });
          render(a, b);
        }
        function preset(name) {
          if (name === "today") return [last, last];
          if (name === "yesterday") return [last - 1, last - 1];
          if (name === "all") return [0, last];
          return [last - Number(name) + 1, last];
        }
        root.querySelectorAll("[data-usage-preset]").forEach(function (el) {
          var name = el.getAttribute("data-usage-preset");
          // A preset longer than the page's window would show the same days as "all".
          if (/^\d+$/.test(name) && Number(name) >= days.length) { el.remove(); return; }
          if (name === "yesterday" && last < 1) { el.remove(); return; }
          el.addEventListener("click", function () { var p = preset(name); apply(p[0], p[1], name); });
        });
        function custom() {
          if (!from.value || !to.value) return;
          // A typed date outside the window becomes the window's nearest day.
          var at = function (v) { return v < days[0] ? 0 : v > days[last] ? last : days.indexOf(v); };
          var a = at(from.value), b = at(to.value);
          if (a < 0 || b < 0) return;
          apply(a, b, "");
        }
        from.min = to.min = days[0]; from.max = to.max = days[last];
        from.addEventListener("change", custom);
        to.addEventListener("change", custom);
        var first = last >= 7 ? "7" : "all";
        var p = preset(first);
        apply(p[0], p[1], first);
      })();
    </script>
    """
  end

  @doc "A free quota amount in its unit (dollars of model cost or a count)."
  def quota_value(n, "usd"), do: usd(n)
  def quota_value(n, _), do: Integer.to_string(round(n))

  @doc "Share of a quota used, 0..1."
  def quota_share(used, limit) when is_number(limit) and limit > 0, do: min(used / limit, 1.0)
  def quota_share(_, _), do: 0.0

  @doc "Bar and text color of a quota: red when full, amber from 80%."
  def quota_color(used, limit) do
    share = if limit > 0, do: used / limit, else: 0

    cond do
      share >= 1 -> {"bg-red-500", "text-red-600 dark:text-red-400 font-semibold"}
      share >= 0.8 -> {"bg-amber-500", "text-amber-600 dark:text-amber-400 font-semibold"}
      true -> {"bg-indigo-500", ""}
    end
  end

  @doc "HH:MM of a unix second in a timezone."
  def local_time(unix, tz) when is_number(unix) do
    unix
    |> round()
    |> DateTime.from_unix!()
    |> DateTime.shift_zone!(tz || "Etc/UTC")
    |> Calendar.strftime("%H:%M")
  end

  def local_time(_, _), do: "—"

  @doc "HH:MM in a timezone at which the next UTC day starts (moves with daylight saving)."
  def utc_day_start(tz, now \\ System.os_time(:second)) do
    local_time((div(now, 86_400) + 1) * 86_400, tz)
  end

  @doc "On how many of the days before today a quota (by index) filled up."
  def days_full(fq, index) do
    fq["days"]
    |> Enum.reject(&(&1["day"] == fq["today"]))
    |> Enum.count(&(Enum.at(&1["cells"], index)["fullAt"] != nil))
  end

  @doc "How often a quota filled up on the days before today."
  def full_days_label(0, 1), do: "Not full yesterday"
  def full_days_label(1, 1), do: "Also full yesterday"
  def full_days_label(0, past), do: "Not full in the last #{past} days"
  def full_days_label(full, past), do: "Full on #{full} of the last #{past} days"

  @doc "Days before today that a quota history covers."
  def past_quota_days(fq), do: Enum.count(fq["days"], &(&1["day"] != fq["today"]))

  @doc "Time left until a unix second, as \"5h 12m\"."
  def time_left(at, now \\ System.os_time(:second)) do
    mins = max(div(at - now, 60), 0)
    if mins >= 60, do: "#{div(mins, 60)}h #{rem(mins, 60)}m", else: "#{mins}m"
  end

  @doc "Red below 1×, amber below 3×; a young cohort (still filling) is not colored."
  def payback_class(nil, _), do: "text-gray-400"
  def payback_class(_, false), do: "text-gray-500"
  def payback_class(n, true) when n < 1, do: "text-red-600 dark:text-red-400 font-semibold"
  def payback_class(n, true) when n < 3, do: "text-amber-600 dark:text-amber-400 font-semibold"
  def payback_class(_, true), do: "text-emerald-600 dark:text-emerald-400 font-semibold"

  attr(:row, :map, required: true)
  attr(:colored, :boolean, default: true, doc: "Color the payback (enough sign-ups to judge)")
  attr(:minor, :boolean, default: false, doc: "Folded into Other until the viewer shows it")
  slot(:label, required: true)

  def source_row(assigns) do
    ~H"""
    <tr data-economics-minor={@minor} class={[@minor && "hidden"]}>
      <td class="px-5 py-3 font-medium"><%= render_slot(@label) %></td>
      <td class="px-4 py-3 text-right"><%= @row["signups"] %></td>
      <td class="px-4 py-3 text-right"><%= usd(@row["freeUsd"]) %></td>
      <td class="px-4 py-3 text-right"><%= per(@row["freePerSignup"]) %></td>
      <td class="px-4 py-3 text-right"><%= usd(@row["revenue"]) %></td>
      <td class="px-4 py-3 text-right"><%= @row["buyers"] %></td>
      <td class={["px-4 py-3 text-right", payback_class(@row["payback"], @colored)]}>
        <%= times(@row["payback"]) %>
      </td>
    </tr>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, default: nil)
  attr(:value_class, :any, default: nil)

  def stat(assigns) do
    ~H"""
    <div class="p-5">
      <p class="text-xs text-gray-500 dark:text-gray-400"><%= @label %></p>
      <p class={["mt-2 text-2xl font-semibold tabular-nums", @value_class]}><%= @value %></p>
      <p :if={@note} class="mt-2 text-xs text-gray-500"><%= @note %></p>
    </div>
    """
  end
end
