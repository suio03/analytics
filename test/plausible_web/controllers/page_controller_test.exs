defmodule PlausibleWeb.PageControllerTest do
  use PlausibleWeb.ConnCase, async: true

  setup {PlausibleWeb.FirstLaunchPlug.Test, :skip}

  describe "GET /" do
    setup [:create_user, :log_in]

    test "shows landing page when user not authenticated" do
      assert build_conn() |> get("/") |> html_response(200) =~ "Welcome to Recount!"
    end

    test "footer links our products and no longer points to plausible.io" do
      html = build_conn() |> get("/") |> html_response(200)

      for url <-
            ~w(https://tapemoon.com https://saybrush.com https://muzix.app https://ordalin.com https://ailabelremover.tools) do
        assert html =~ ~s(href="#{url}")
      end

      refute html =~ "self-managed infrastructure"
    end

    test "redirects to /sites if user is authenticated", %{conn: conn} do
      assert conn
             |> get("/")
             |> redirected_to(302) == "/sites"
    end
  end
end
