defmodule Plausible.EconomicsTest do
  use ExUnit.Case, async: true

  alias Plausible.Economics

  test "split_sources folds small sources into Other and puts pre-tracking sign-ups last" do
    rows = [
      %{
        "key" => "chatgpt.com",
        "signups" => 660,
        "freeUsd" => 137,
        "revenue" => 511,
        "buyers" => 10
      },
      %{
        "key" => "(before tracking)",
        "signups" => 107,
        "freeUsd" => 0.25,
        "revenue" => 304,
        "buyers" => 3
      },
      %{"key" => "bing.com", "signups" => 6, "freeUsd" => 1.29, "revenue" => 0, "buyers" => 0},
      %{"key" => "fyndmyai", "signups" => 2, "freeUsd" => 0.66, "revenue" => 0, "buyers" => 0},
      %{"key" => "email", "signups" => 2, "freeUsd" => 0.34, "revenue" => 20, "buyers" => 1}
    ]

    split = Economics.split_sources(rows)

    assert Enum.map(split.major, & &1["key"]) == ["chatgpt.com", "bing.com"]
    assert Enum.map(split.minor, & &1["key"]) == ["fyndmyai", "email"]
    assert Enum.map(split.before, & &1["key"]) == ["(before tracking)"]

    assert %{"count" => 2, "signups" => 4, "buyers" => 1, "revenue" => 20} = split.other
    assert_in_delta split.other["freeUsd"], 1.0, 1.0e-9
    assert_in_delta split.other["freePerSignup"], 0.25, 1.0e-9
    assert_in_delta split.other["payback"], 20.0, 1.0e-9
  end

  test "split_sources has no Other row when every source is large enough" do
    rows = [
      %{"key" => "google", "signups" => 55, "freeUsd" => 12, "revenue" => 128, "buyers" => 4}
    ]

    assert %{other: nil, minor: [], before: []} = Economics.split_sources(rows)
  end

  test "totals: profit is revenue minus free cost minus paying users' cost" do
    rows = [
      %{"signups" => 3, "freeUsd" => 10, "paidUsd" => 4, "revenue" => 50},
      %{"signups" => 2, "freeUsd" => 5, "paidUsd" => 1, "revenue" => 0}
    ]

    assert %{free: 15, paid: 5, revenue: 50, profit: 30, signups: 5} = Economics.totals(rows)
  end
end
