defmodule Plausible.Economics.ReportTest do
  use ExUnit.Case, async: true
  alias Plausible.Economics.Report

  @tz "Australia/Melbourne"
  # 2026-11-10 21:00 in Melbourne (UTC+11)
  @now DateTime.to_unix(~U[2026-11-10 10:00:00Z])

  defp at(dt), do: DateTime.to_unix(dt)

  @raw %{
    "format" => 2,
    "generatedAt" => "2026-11-10T10:00:00Z",
    "notes" => ["Free cost: model calls."],
    "users" => [
      # 01:30 on Nov 10 in Melbourne, still Nov 9 in UTC
      %{"id" => "late", "at" => DateTime.to_unix(~U[2026-11-09 14:30:00Z]), "source" => "taaft"},
      %{
        "id" => "buyer",
        "at" => DateTime.to_unix(~U[2026-11-04 00:00:00Z]),
        "referrer" => "www.google.com"
      },
      %{
        "id" => "guest",
        "at" => DateTime.to_unix(~U[2026-11-05 00:00:00Z]),
        "guest" => true,
        "referrer" => "accounts.google.com"
      },
      %{"id" => "old", "at" => DateTime.to_unix(~U[2026-11-04 01:00:00Z]), "tracked" => false},
      # before the window (Nov 4 00:00 Melbourne = Nov 3 13:00 UTC)
      %{"id" => "outside", "at" => DateTime.to_unix(~U[2026-11-03 12:59:00Z])}
    ],
    "costs" => [
      %{
        "user" => "late",
        "at" => DateTime.to_unix(~U[2026-11-09 14:30:00Z]),
        "free" => 0.5,
        "paid" => 0
      },
      %{
        "user" => "buyer",
        "at" => DateTime.to_unix(~U[2026-11-04 00:15:00Z]),
        "free" => 2.0,
        "paid" => 0
      },
      %{
        "user" => "guest",
        "at" => DateTime.to_unix(~U[2026-11-05 00:15:00Z]),
        "free" => 1.0,
        "paid" => 0
      },
      %{
        "user" => nil,
        "at" => DateTime.to_unix(~U[2026-11-08 02:00:00Z]),
        "free" => 0,
        "paid" => 0.25
      },
      %{
        "user" => "outside",
        "at" => DateTime.to_unix(~U[2026-11-03 12:00:00Z]),
        "free" => 9.0,
        "paid" => 0
      }
    ],
    "orders" => [
      %{
        "user" => "buyer",
        "at" => DateTime.to_unix(~U[2026-11-08 00:00:00Z]),
        "usd" => 20.0,
        "first" => true
      },
      %{"user" => "someone", "at" => DateTime.to_unix(~U[2026-11-08 01:00:00Z]), "usd" => 5.0}
    ]
  }

  test "the window is local days ending today" do
    assert Report.since(@tz, 7, @now) == at(~U[2026-11-03 13:00:00Z])
    assert Report.since("Etc/UTC", 7, @now) == at(~U[2026-11-04 00:00:00Z])
  end

  test "a local midnight inside a DST gap starts at the first moment after it" do
    # Santiago skips 00:00–01:00 on 2026-09-06
    now = at(~U[2026-09-12 12:00:00Z])
    assert Report.since("America/Santiago", 7, now) == at(~U[2026-09-06 04:00:00Z])
  end

  test "days are local: a sign-up at 01:30 Melbourne counts on that Melbourne day" do
    report = Report.build(@raw, @tz, 7, @now)
    assert report["timezone"] == @tz
    assert report["today"] == "2026-11-10"
    assert length(report["daily"]) == 7
    assert [today | _] = report["daily"]
    assert today["day"] == "2026-11-10"
    assert today["signups"] == 1
    assert today["freeUsd"] == 0.5

    by_day = Map.new(report["daily"], &{&1["day"], &1})
    assert by_day["2026-11-04"]["signups"] == 2
    assert by_day["2026-11-04"]["freeUsd"] == 2.0
    assert by_day["2026-11-05"]["guests"] == 1
    assert by_day["2026-11-05"]["signups"] == 0
    assert by_day["2026-11-08"]["orders"] == 2
    assert by_day["2026-11-08"]["firstOrders"] == 1
    assert by_day["2026-11-08"]["revenue"] == 25.0
    assert by_day["2026-11-08"]["paidUsd"] == 0.25
    # empty days are listed too
    assert by_day["2026-11-06"]["signups"] == 0
  end

  test "sources group first touches and only count the window's accounts" do
    report = Report.build(@raw, @tz, 7, @now)
    sources = Map.new(report["sources"], &{&1["key"], &1})

    assert Map.keys(sources) |> Enum.sort() ==
             ["(before tracking)", "(direct or unknown)", "google", "taaft"]

    assert %{"signups" => 1, "buyers" => 1, "revenue" => 20.0, "freeUsd" => 2.0} =
             sources["google"]

    assert sources["google"]["payback"] == 10.0
    assert %{"signups" => 0, "guests" => 1, "freeUsd" => 1.0} = sources["(direct or unknown)"]
    assert sources["(before tracking)"]["payback"] == nil

    assert Enum.any?(report["notes"], &(&1 =~ "1 guests"))
  end

  test "weeks start on the local Monday and are full only #{30} days after they end" do
    report = Report.build(@raw, @tz, 7, @now)

    assert [%{"key" => "2026-11-09", "age" => 0}, %{"key" => "2026-11-02", "age" => 1} = w] =
             report["weeks"]

    assert w["signups"] == 2

    later = at(~U[2026-12-08 13:00:00Z])

    assert Report.build(@raw, @tz, 180, later)["weeks"]
           |> Enum.find(&(&1["key"] == "2026-11-02"))
           |> Map.fetch!("age") == 30
  end

  test "source keys" do
    assert Report.source_key(%{"source" => "chatgpt.com", "referrer" => "x.com"}) == "chatgpt.com"
    assert Report.source_key(%{"source" => " ", "referrer" => "www.bing.com"}) == "bing"
    assert Report.source_key(%{"referrer" => "www.google.co.uk"}) == "google"
    assert Report.source_key(%{"referrer" => "appleid.apple.com"}) == "(direct or unknown)"
    assert Report.source_key(%{"referrer" => "www.nextgeeker.com"}) == "nextgeeker.com"
    assert Report.source_key(%{"tracked" => false}) == "(before tracking)"
    assert Report.source_key(%{}) == "(direct or unknown)"
  end

  test "raw? tells the export from a format 1 report" do
    assert Report.raw?(@raw)
    refute Report.raw?(%{"daily" => [], "weeks" => [], "sources" => []})
  end
end
