defmodule PlausibleWeb.Favicon do
  @referer_domains_file "priv/referer_favicon_domains.json"
  @moduledoc """
  A Plug that fetches favicon images from DuckDuckGo with Google fallback and returns them
  to the Plausible frontend.

  The proxying is there so we can reduce the number of third-party domains that
  the browser clients need to connect to. Our goal is to have 0 third-party domain
  connections on the website for privacy reasons.

  This module also maps between categorized sources and their respective URLs for favicons.
  What does that mean exactly? During ingestion we use `PlausibleWeb.RefInspector.parse/1` to
  categorize our referrer sources like so:

  google.com -> Google
  google.co.uk -> Google
  google.com.au -> Google

  So when we show Google as a source in the dashboard, the request to this plug will come as:
  https://plausible/io/favicon/sources/Google

  Now, when we want to show a favicon for Google, we need to convert Google -> google.com or
  some other hostname owned by Google:
  https://icons.duckduckgo.com/ip3/google.com.ico

  The mapping from source category -> source hostname is stored in "#{@referer_domains_file}" and
  managed by `Mix.Tasks.GenerateReferrerFavicons.run/1`
  """
  import Plug.Conn
  alias Plausible.HTTPClient

  @placeholder_icon_location "priv/placeholder_favicon.ico"
  @placeholder_icon File.read!(@placeholder_icon_location)

  def init(_) do
    domains =
      File.read!(Application.app_dir(:plausible, @referer_domains_file))
      |> Jason.decode!()

    [favicon_domains: domains]
  end

  @ddg_broken_icon <<137, 80, 78, 71, 13, 10, 26, 10>>
  @doc """
  Proxies HTTP requests to DuckDuckGo, falling back to Google favicon service. Swallows hop-by-hop HTTP
  headers that should not be forwarded as defined in [RFC 2616](https://www.rfc-editor.org/rfc/rfc2616#section-13.5.1)

  ## Placeholder

  When both providers fail, we cache a placeholder for one hour.
  Provider failures include:

  1. Network errors
  2. Non-200 status codes
  3. Empty bodies or the known broken PNG response

  I'm not sure why DDG sometimes returns a broken PNG image in their response
  but we filter that out.  When the icon request fails, we show a placeholder
  favicon instead. The placeholder is an emoji from
  [https://favicon.io/emoji-favicons/](https://favicon.io/emoji-favicons/)

  DuckDuckGo favicon service has some issues with [SVG favicons](https://css-tricks.com/svg-favicons-and-all-the-fun-things-we-can-do-with-them/).
  For some reason, they return them with `content-type=image/x-icon` whereas SVG
  icons should be returned with `content-type=image/svg+xml`. This Plug detects
  when the response body starts with `<svg` and will override the `Content-Type`
  to correct it.

  ## Preventing XSS vulnerabilities

  SVGs may contain `<script>` tags, and as these SVGs come from external
  sources, we need to prevent untrusted code from running on the browser.

  - This Plug sets a strict `Content-Security-Policy` header telling the browser
    not to run scripts.

  - This Plug sets `Content-Disposition=attachment` to prevent the SVG from
    rendering when navigating to `/favicon/sources/:domain` directly.

  - Browsers do not execute scripts from `<img>` tags, therefore it is safe to
    use `<img src="https://plausible.io/favicon/sources/dummy.site"></img>`

  """
  def call(conn, favicon_domains: favicon_domains) do
    case conn.request_path do
      "/favicon/sources/placeholder" ->
        send_placeholder(conn)

      "/favicon/sources/" <> source ->
        clean_source = URI.decode_www_form(source)
        domain = Map.get(favicon_domains, clean_source, clean_source)

        case fetch_icon(domain) do
          {:ok, %Finch.Response{body: body, headers: headers}} ->
            conn
            |> forward_headers(headers)
            |> maybe_override_content_type(body)
            |> prevent_javascript_execution()
            |> send_resp(200, body)
            |> halt()

          _ ->
            send_placeholder(conn)
        end

      _ ->
        conn
    end
  end

  defp fetch_icon(domain) do
    case fetch_valid_icon("https://icons.duckduckgo.com/ip3/#{domain}.ico") do
      {:ok, _} = response -> response
      _ -> fetch_valid_icon(google_icon_url(domain))
    end
  end

  defp google_icon_url(domain) do
    # Google's /s2/favicons endpoint redirects; Finch does not follow redirects.
    query =
      URI.encode_query(
        client: "SOCIAL",
        type: "FAVICON",
        fallback_opts: "TYPE,SIZE,URL",
        url: "https://#{domain}",
        size: 64
      )

    "https://t1.gstatic.com/faviconV2?#{query}"
  end

  defp fetch_valid_icon(url) do
    case HTTPClient.impl().get(url) do
      {:ok, %Finch.Response{status: 200, body: body}} = response
      when is_binary(body) and body != "" and body != @ddg_broken_icon ->
        response

      _ ->
        :error
    end
  end

  defp send_placeholder(conn) do
    conn
    |> put_resp_content_type("image/x-icon")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, @placeholder_icon)
    |> halt
  end

  @forwarded_headers ["content-type", "cache-control", "expires"]
  defp forward_headers(conn, headers) do
    headers_to_forward = Enum.filter(headers, fn {k, _} -> k in @forwarded_headers end)
    %Plug.Conn{conn | resp_headers: headers_to_forward}
  end

  defp maybe_override_content_type(conn, "<svg" <> _rest) do
    conn |> put_resp_content_type("image/svg+xml")
  end

  defp maybe_override_content_type(conn, _), do: conn

  defp prevent_javascript_execution(conn) do
    conn
    |> put_resp_header("content-security-policy", "script-src 'none'")
    |> put_resp_header("content-disposition", "attachment")
  end
end
