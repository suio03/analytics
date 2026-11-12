defmodule Plausible.Economics.Report do
  @moduledoc """
  Builds the Economics report from an app's raw export (format 2, docs/economics.md): accounts,
  model cost in 15-minute buckets and paid orders. Days and weeks are the site's local ones, so
  every reporting rule lives here and the apps only export facts.
  """

  @day 86_400
  @cohort_days 30

  def cohort_days, do: @cohort_days

  @doc "True when the body is a raw export rather than a report computed by the app (format 1)."
  def raw?(%{"users" => u, "costs" => c, "orders" => o})
      when is_list(u) and is_list(c) and is_list(o),
      do: true

  def raw?(_), do: false

  @doc "Unix second at which the window of `days` local days ending today starts."
  def since(tz, days, now \\ System.os_time(:second)) do
    today = local_date(now, tz)
    midnight(Date.add(today, 1 - days), tz)
  end

  @doc "The report in the shape the page renders (same keys as a format 1 report)."
  def build(raw, tz, days, now \\ System.os_time(:second)) do
    today = local_date(now, tz)
    start = Date.add(today, 1 - days)
    since = midnight(start, tz)

    users =
      for u <- raw["users"], num(u["at"]) >= since do
        %{
          id: u["id"],
          at: num(u["at"]),
          guest: u["guest"] == true,
          date: local_date(num(u["at"]), tz),
          source: source_key(u)
        }
      end

    costs =
      for c <- raw["costs"], num(c["at"]) >= since do
        %{
          user: c["user"],
          date: local_date(num(c["at"]), tz),
          free: num(c["free"]),
          paid: num(c["paid"])
        }
      end

    orders =
      for o <- raw["orders"], num(o["at"]) >= since do
        %{
          user: o["user"],
          at: num(o["at"]),
          date: local_date(num(o["at"]), tz),
          usd: num(o["usd"]),
          first: o["first"] == true
        }
      end

    guests = Enum.count(users, & &1.guest)

    %{
      "format" => 2,
      "generatedAt" => raw["generatedAt"],
      "days" => days,
      "timezone" => tz,
      "today" => Date.to_iso8601(today),
      "cohortDays" => @cohort_days,
      "notes" => notes(raw["notes"], guests, days),
      "daily" => daily(start, today, users, costs, orders),
      "weeks" => weeks(users, costs, orders, tz, now),
      "sources" => sources(users, costs, orders),
      "payers" => payers(raw["payers"], since),
      "freeQuotas" => free_quotas(raw["freeQuotas"], now)
    }
  end

  @quota_days 7

  @doc """
  The app's free daily quotas (UTC days): today's use of each quota and the last #{@quota_days}
  days, newest first, starting at the first day the app has use for. Nil when the app doesn't
  export them.
  """
  def free_quotas(%{"quotas" => quotas, "days" => days}, now)
      when is_list(quotas) and is_list(days) do
    today = now |> DateTime.from_unix!() |> DateTime.to_date()

    quotas =
      for q <- quotas,
          is_map(q) and is_binary(q["key"]) and is_number(q["limit"]) and q["limit"] > 0 do
        %{
          "key" => q["key"],
          "label" => if(is_binary(q["label"]), do: q["label"], else: q["key"]),
          "unit" => if(q["unit"] == "usd", do: "usd", else: "count"),
          "limit" => q["limit"]
        }
      end

    use =
      for d <- days, is_map(d), date = quota_date(d["day"]), date != nil, into: %{} do
        {{date, d["key"]},
         %{"used" => num(d["used"]), "fullAt" => if(is_number(d["fullAt"]), do: d["fullAt"])}}
      end

    earliest = use |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.min(Date, fn -> today end)
    first = Enum.min([Enum.max([earliest, Date.add(today, 1 - @quota_days)], Date), today], Date)

    cell = fn date, key -> Map.get(use, {date, key}, %{"used" => 0, "fullAt" => nil}) end

    if quotas != [] do
      %{
        "today" => Date.to_iso8601(today),
        "resetsAt" => DateTime.to_unix(DateTime.new!(Date.add(today, 1), ~T[00:00:00])),
        "quotas" => Enum.map(quotas, &Map.merge(&1, cell.(today, &1["key"]))),
        "days" =>
          for date <- Date.range(today, first, -1) do
            %{
              "day" => Date.to_iso8601(date),
              "cells" => Enum.map(quotas, &cell.(date, &1["key"]))
            }
          end
      }
    end
  end

  def free_quotas(_, _), do: nil

  defp quota_date(day) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp quota_date(_), do: nil

  @doc """
  Accounts that paid within the window (any paid order since `since`), with the app's lifetime
  totals, most paid first. Nil when the app doesn't export payers.
  """
  def payers(rows, since) when is_list(rows) do
    rows
    |> Enum.filter(&(is_map(&1) and num(&1["lastPaidAt"]) >= since))
    |> Enum.map(fn p ->
      credits = if is_map(p["credits"]), do: p["credits"], else: %{}
      billing = country(p["billingCountry"])
      signup = country(p["signupCountry"])
      usd = num(p["usd"])
      cost = num(p["costUsd"])

      %{
        "id" => p["id"],
        "email" => p["email"],
        "source" => source_key(p),
        "platform" => p["platform"],
        "country" => billing || signup,
        "countryFrom" =>
          cond do
            billing -> "billing"
            signup -> "sign-up"
            true -> nil
          end,
        "plan" => blank_to_nil(p["plan"]),
        "lastSku" => blank_to_nil(p["lastSku"]),
        "orders" => num(p["orders"]),
        "usd" => usd,
        "refunds" => num(p["refunds"]),
        "refundedUsd" => num(p["refundedUsd"]),
        "new" => num(p["firstPaidAt"]) >= since,
        "daysToPay" =>
          if(is_number(p["firstPaidAt"]) and is_number(p["at"]),
            do: max(div(p["firstPaidAt"] - p["at"], @day), 0)
          ),
        "lastPaidAt" => num(p["lastPaidAt"]),
        "lastActiveAt" => if(is_number(p["lastActiveAt"]), do: p["lastActiveAt"]),
        "creditsBought" => num(credits["bought"]),
        "creditsGranted" => num(credits["granted"]),
        "creditsUsed" => num(credits["used"]),
        "creditsLeft" => num(credits["left"]),
        "costUsd" => cost,
        "margin" => usd - cost
      }
    end)
    |> Enum.sort_by(&{-&1["usd"], -&1["lastPaidAt"]})
  end

  def payers(_, _), do: nil

  defp country(c) when is_binary(c) do
    c = c |> String.trim() |> String.upcase()
    if String.match?(c, ~r/^[A-Z]{2}$/), do: c
  end

  defp country(_), do: nil

  @doc """
  First-touch source of an account: utm_source / ?ref= when set, else the referring site (search
  engines grouped, they send no utm). Sign-in redirects are not sources. Accounts from before the
  app recorded first touches (`tracked: false`) are their own group, so they don't pass for direct.
  """
  def source_key(u) do
    source = blank_to_nil(u["source"])
    referrer = blank_to_nil(u["referrer"])

    cond do
      source ->
        source

      referrer && (String.starts_with?(referrer, "accounts.") or referrer == "appleid.apple.com") ->
        "(direct or unknown)"

      referrer && String.contains?(referrer, "google.") ->
        "google"

      referrer && String.ends_with?(referrer, "bing.com") ->
        "bing"

      referrer ->
        String.replace_prefix(referrer, "www.", "")

      u["tracked"] == false ->
        "(before tracking)"

      true ->
        "(direct or unknown)"
    end
  end

  defp daily(start, today, users, costs, orders) do
    users = Enum.group_by(users, & &1.date)
    costs = Enum.group_by(costs, & &1.date)
    orders = Enum.group_by(orders, & &1.date)

    for date <- Date.range(today, start, -1) do
      u = Map.get(users, date, [])
      c = Map.get(costs, date, [])
      o = Map.get(orders, date, [])

      %{
        "day" => Date.to_iso8601(date),
        "signups" => Enum.count(u, &(!&1.guest)),
        "guests" => Enum.count(u, & &1.guest),
        "freeUsd" => sum(c, :free),
        "paidUsd" => sum(c, :paid),
        "orders" => length(o),
        "firstOrders" => Enum.count(o, & &1.first),
        "revenue" => sum(o, :usd)
      }
    end
  end

  defp weeks(users, costs, orders, tz, now) do
    users
    |> cohorts(&Date.beginning_of_week(&1.date), costs, orders)
    |> Enum.map(fn {week, row} ->
      # Days since the week ended, so a "full" week has given every sign-up its whole window.
      ended = midnight(Date.add(week, 7), tz)
      age = (now - ended) |> div(@day) |> max(0) |> min(@cohort_days)
      row |> Map.put("key", Date.to_iso8601(week)) |> Map.put("age", age)
    end)
    |> Enum.sort_by(& &1["key"], :desc)
  end

  defp sources(users, costs, orders) do
    users
    |> cohorts(& &1.source, costs, orders)
    |> Enum.map(fn {key, row} -> Map.put(row, "key", key) end)
    |> Enum.sort_by(&{-&1["signups"], -&1["freeUsd"], &1["key"]})
  end

  # One row per group of accounts. Free cost is what the group's accounts cost before paying;
  # revenue is their paid orders within @cohort_days of their own sign-up.
  defp cohorts(users, group, costs, orders) do
    free_by_user =
      Enum.reduce(costs, %{}, fn
        %{user: nil}, acc -> acc
        c, acc -> Map.update(acc, c.user, c.free, &(&1 + c.free))
      end)

    orders_by_user = Enum.group_by(orders, & &1.user)

    users
    |> Enum.group_by(group)
    |> Enum.map(fn {key, members} ->
      free = members |> Enum.map(&Map.get(free_by_user, &1.id, 0)) |> Enum.sum()

      paid =
        for u <- members,
            o <- Map.get(orders_by_user, u.id, []),
            o.at < u.at + @cohort_days * @day,
            do: o

      revenue = sum(paid, :usd)
      signups = Enum.count(members, &(!&1.guest))

      {key,
       %{
         "signups" => signups,
         "guests" => length(members) - signups,
         "buyers" => paid |> Enum.uniq_by(& &1.user) |> length(),
         "freeUsd" => free,
         "revenue" => revenue,
         "freePerSignup" => if(signups > 0, do: free / signups, else: 0),
         "revenuePerSignup" => if(signups > 0, do: revenue / signups, else: 0),
         "payback" => if(free > 0, do: revenue / free)
       }}
    end)
  end

  defp notes(app_notes, guests, days) do
    List.wrap(app_notes) ++
      [
        "Cohort revenue: paid orders within #{@cohort_days} days of sign-up, before payment fees.",
        "Payback: cohort revenue ÷ cohort free cost."
      ] ++
      if guests > 0,
        do: [
          "Free cost includes #{guests} guests from these #{days} days who have not signed in; they are not counted as sign-ups, so per sign-up includes their share."
        ],
        else: []
  end

  defp local_date(unix, tz) do
    unix |> DateTime.from_unix!() |> DateTime.shift_zone!(tz) |> DateTime.to_date()
  end

  # Unix second of a local date's first moment (after a DST gap, or the first of two at a fold).
  defp midnight(date, tz) do
    dt =
      case DateTime.new(date, ~T[00:00:00], tz) do
        {:ok, dt} -> dt
        {:ambiguous, first, _} -> first
        {:gap, _, just_after} -> just_after
      end

    DateTime.to_unix(dt)
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &(Map.get(&1, key) + &2))

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil
end
