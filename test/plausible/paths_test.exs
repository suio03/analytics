defmodule Plausible.PathsTest do
  use ExUnit.Case, async: true

  alias Plausible.Paths

  describe "normalize_path/1" do
    test "drops locale prefixes, query strings and identifiers" do
      assert Paths.normalize_path("/ja/pricing") == "/pricing"
      assert Paths.normalize_path("/pt-br/dashboard/new") == "/dashboard/new"
      assert Paths.normalize_path("/es") == "/"
      assert Paths.normalize_path("/pricing?ref=abc#plans") == "/pricing"

      assert Paths.normalize_path("/dashboard/transcripts/cfbec2a4-4a01-4a4d-82f9-731d6ead8739") ==
               "/dashboard/transcripts/:id"

      assert Paths.normalize_path("/orders/12345/edit") == "/orders/:id/edit"
      assert Paths.normalize_path("/share/a8Kd93jLm2Qp0xYz") == "/share/:id"
    end

    test "keeps ordinary segments that resemble locales or words" do
      assert Paths.normalize_path("/japan/guide") == "/japan/guide"
      assert Paths.normalize_path("/ai-note-taker") == "/ai-note-taker"
      assert Paths.normalize_path("/youtube-to-transcript") == "/youtube-to-transcript"
      assert Paths.normalize_path("") == "/"
      assert Paths.normalize_path(nil) == "/"
    end
  end

  describe "step_label/5" do
    test "pageviews become normalized paths" do
      assert Paths.step_label("pageview", "/fr/pricing", [], [], []) == "/pricing"
    end

    test "events keep only requested enum-like prop values" do
      keys = ["reason", "error_message", "tool_slug"]
      values = ["quota", "Upload failed: network down", "home"]

      assert Paths.step_label("upgrade_cta_shown", "/", keys, values, []) == "upgrade_cta_shown"

      assert Paths.step_label("upgrade_cta_shown", "/", keys, values, ["tool_slug", "reason"]) ==
               "upgrade_cta_shown(reason=quota,tool_slug=home)"

      assert Paths.step_label("transcribe_fail", "/", keys, values, ["error_message"]) ==
               "transcribe_fail"
    end
  end
end
