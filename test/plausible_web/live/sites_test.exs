defmodule PlausibleWeb.Live.SitesTest do
  use PlausibleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Plausible.Test.Support.HTML

  alias Plausible.Repo

  setup [:create_user, :log_in]

  describe "/sites" do
    test "renders empty sites page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sites")

      assert text(html) =~ "You don't have any sites yet"
    end

    @tag :ee_only
    test "renders ownership transfer invitation for a case with no plan", %{
      conn: conn,
      user: user
    } do
      site = insert(:site)

      invitation =
        insert(:invitation,
          site_id: site.id,
          inviter: build(:user),
          email: user.email,
          role: :owner
        )

      {:ok, _lv, html} = live(conn, "/sites")

      invitation_data = get_invitation_data(html)

      assert get_in(invitation_data, ["invitations", invitation.invitation_id, "no_plan"])
    end

    @tag :ee_only
    test "renders ownership transfer invitation for a case with exceeded limits", %{
      conn: conn,
      user: user
    } do
      site = insert(:site)

      insert(:growth_subscription, user: user)

      # fill site quota
      insert_list(10, :site, members: [user])

      invitation =
        insert(:invitation,
          site_id: site.id,
          inviter: build(:user),
          email: user.email,
          role: :owner
        )

      {:ok, _lv, html} = live(conn, "/sites")

      invitation_data = get_invitation_data(html)

      assert get_in(invitation_data, ["invitations", invitation.invitation_id, "exceeded_limits"]) ==
               "site limit"
    end

    @tag :ee_only
    test "renders ownership transfer invitation for a case with missing features", %{
      conn: conn,
      user: user
    } do
      site = insert(:site, allowed_event_props: ["dummy"])

      insert(:growth_subscription, user: user)

      invitation =
        insert(:invitation,
          site_id: site.id,
          inviter: build(:user),
          email: user.email,
          role: :owner
        )

      {:ok, _lv, html} = live(conn, "/sites")

      invitation_data = get_invitation_data(html)

      assert get_in(invitation_data, ["invitations", invitation.invitation_id, "missing_features"]) ==
               "Custom Properties"
    end

    test "renders 24h visitors correctly", %{conn: conn, user: user} do
      site = insert(:site, members: [user])

      populate_stats(site, [build(:pageview), build(:pageview), build(:pageview)])

      {:ok, _lv, html} = live(conn, "/sites")

      site_card = text_of_element(html, "li[data-domain=\"#{site.domain}\"]")
      assert site_card =~ "3 visitors in last 24h"
      assert site_card =~ site.domain
    end

    test "shows suspicious and bot visitors next to the human count", %{conn: conn, user: user} do
      site = insert(:site, members: [user])
      quiet_site = insert(:site, members: [user])

      populate_stats(site, [
        build(:pageview),
        build(:pageview, traffic: 1),
        build(:pageview, traffic: 2),
        build(:pageview, traffic: 2)
      ])

      populate_stats(quiet_site, [build(:pageview)])

      {:ok, _lv, html} = live(conn, "/sites")

      site_card = text_of_element(html, "li[data-domain=\"#{site.domain}\"]")
      assert site_card =~ "1 visitor in last 24h"
      assert site_card =~ "+1 suspicious"
      assert site_card =~ "+2 bots"

      refute element_exists?(
               html,
               "li[data-domain=\"#{quiet_site.domain}\"] [data-test-id=nonhuman-note]"
             )

      assert element_exists?(
               html,
               "li[data-domain=\"#{site.domain}\"] [data-test-id=nonhuman-note]"
             )
    end

    test "filters by domain", %{conn: conn, user: user} do
      _site1 = insert(:site, domain: "first.example.com", members: [user])
      _site2 = insert(:site, domain: "second.example.com", members: [user])
      _site3 = insert(:site, domain: "first-another.example.com", members: [user])

      {:ok, lv, _html} = live(conn, "/sites")

      type_into_input(lv, "filter_text", "firs")
      html = render(lv)

      assert html =~ "first.example.com"
      assert html =~ "first-another.example.com"
      refute html =~ "second.example.com"
    end

    test "filtering plays well with pagination", %{conn: conn, user: user} do
      _site1 = insert(:site, domain: "first.another.example.com", members: [user])
      _site2 = insert(:site, domain: "second.example.com", members: [user])
      _site3 = insert(:site, domain: "third.another.example.com", members: [user])

      {:ok, lv, html} = live(conn, "/sites?page_size=2")

      assert html =~ "first.another.example.com"
      assert html =~ "second.example.com"
      refute html =~ "third.another.example.com"
      assert html =~ "page=2"
      refute html =~ "page=1"

      type_into_input(lv, "filter_text", "anot")
      html = render(lv)

      assert html =~ "first.another.example.com"
      refute html =~ "second.example.com"
      assert html =~ "third.another.example.com"
      refute html =~ "page=1"
      refute html =~ "page=2"
    end
  end

  describe "collapsing" do
    test "collapsed site leaves the grid for the collapsed row and comes back", %{
      conn: conn,
      user: user
    } do
      site = insert(:site, members: [user])

      {:ok, lv, _html} = live(conn, "/sites")

      html =
        lv
        |> element(~s/li[data-domain="#{site.domain}"] a[data-collapse-site]/)
        |> render_click()

      refute element_exists?(html, ~s/#site-grid li[data-domain="#{site.domain}"]/)
      assert element_exists?(html, ~s/#collapsed-sites li[data-domain="#{site.domain}"]/)
      assert text_of_element(html, "#collapsed-sites h3") == "Collapsed · 1"

      html =
        lv
        |> element(~s/#collapsed-sites button[phx-value-domain="#{site.domain}"]/)
        |> render_click()

      assert element_exists?(html, ~s/#site-grid li[data-domain="#{site.domain}"]/)
      refute element_exists?(html, "#collapsed-sites")
    end

    test "collapsed state persists", %{conn: conn, user: user} do
      site = insert(:site, members: [user])
      Plausible.Sites.set_collapsed(user, site, true)

      {:ok, _lv, html} = live(conn, "/sites")

      assert element_exists?(html, ~s/#collapsed-sites li[data-domain="#{site.domain}"]/)
    end

    test "does not collapse a site the user doesn't have access to", %{conn: conn, user: user} do
      site = insert(:site)

      {:ok, lv, _html} = live(conn, "/sites")

      render_click(lv, "collapse", %{"domain" => site.domain})

      refute Repo.get_by(Plausible.Site.UserPreference, user_id: user.id, site_id: site.id)
    end
  end

  describe "reordering" do
    test "keeps the dragged order", %{conn: conn, user: user} do
      a = insert(:site, domain: "a.example.com", members: [user])
      b = insert(:site, domain: "b.example.com", members: [user])
      c = insert(:site, domain: "c.example.com", members: [user])

      {:ok, lv, html} = live(conn, "/sites")
      assert grid_domains(html) == [a.domain, b.domain, c.domain]

      render_hook(lv, "reorder", %{"domains" => [c.domain, a.domain, b.domain]})

      {:ok, _lv, html} = live(conn, "/sites")
      assert grid_domains(html) == [c.domain, a.domain, b.domain]
    end

    test "ignores sites the user doesn't have access to", %{conn: conn, user: user} do
      mine = insert(:site, members: [user])
      other = insert(:site)

      {:ok, lv, _html} = live(conn, "/sites")
      render_hook(lv, "reorder", %{"domains" => [other.domain, mine.domain]})

      refute Repo.get_by(Plausible.Site.UserPreference, user_id: user.id, site_id: other.id)

      assert Repo.get_by(Plausible.Site.UserPreference, user_id: user.id, site_id: mine.id).position ==
               0
    end

    test "is disabled while searching", %{conn: conn, user: user} do
      a = insert(:site, domain: "a.example.com", members: [user])
      b = insert(:site, domain: "b.example.com", members: [user])

      {:ok, lv, _html} = live(conn, "/sites")
      type_into_input(lv, "filter_text", "example")
      html = render_hook(lv, "reorder", %{"domains" => [b.domain, a.domain]})

      refute element_exists?(html, "[data-site-handle]")
      refute Repo.get_by(Plausible.Site.UserPreference, user_id: user.id, site_id: a.id)
    end
  end

  defp grid_domains(html) do
    html
    |> find("#site-grid li[data-sortable]")
    |> Enum.map(&text_of_attr(&1, "data-domain"))
  end

  defp type_into_input(lv, id, text) do
    lv
    |> element("form")
    |> render_change(%{id => text})
  end

  defp get_invitation_data(html) do
    html
    |> text_of_attr("div[x-data]", "x-data")
    |> String.trim("dropdown")
    |> String.replace("selectedInvitation:", "\"selectedInvitation\":")
    |> String.replace("invitationOpen:", "\"invitationOpen\":")
    |> String.replace("invitations:", "\"invitations\":")
    |> Jason.decode!()
  end
end
