import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader(
    "plausible_admin", str(Path(__file__).resolve().parents[2] / "bin/plausible-admin")
)
spec = importlib.util.spec_from_loader(loader.name, loader)
admin = importlib.util.module_from_spec(spec)
loader.exec_module(admin)


class PropertiesTests(unittest.TestCase):
    def test_batch_is_one_authenticated_additive_request(self):
        captured = []
        def open_request(request, timeout):
            captured.append(request)
            return io.BytesIO(b'{"properties":["tool_slug","outcome","stage"],"added":["outcome","stage"]}')
        with patch.object(admin.urllib.request, "urlopen", side_effect=open_request):
            result = admin.Client("https://analytics.test", "test-key").add_properties(
                "pixfy.io", ["outcome", "stage"]
            )
        self.assertEqual(len(captured), 1)
        request = captured[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.full_url, "https://analytics.test/api/v1/admin/properties")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-key")
        self.assertEqual(json.loads(request.data),
                         {"site_id": "pixfy.io", "properties": ["outcome", "stage"]})
        self.assertIn("tool_slug", result["properties"])

    def test_cli_dispatches_batch_and_reports_added_names(self):
        args = ["plausible-admin", "--url", "https://analytics.test", "--api-key", "test-key",
                "properties", "add", "pixfy.io", "outcome", "stage", "error_category"]
        output = io.StringIO()
        with patch("sys.argv", args), patch.object(
            admin.Client, "add_properties",
            return_value={"properties": ["outcome", "stage", "error_category"], "added": ["stage"]}
        ) as add, contextlib.redirect_stdout(output):
            self.assertEqual(admin.main(), 0)
        add.assert_called_once_with("pixfy.io", ["outcome", "stage", "error_category"])
        self.assertIn("Added: stage", output.getvalue())

    def test_list_uses_get_and_encodes_site(self):
        with patch.object(admin.urllib.request, "urlopen", return_value=io.BytesIO(b'{"properties":[]}')) as op:
            admin.Client("https://analytics.test", "test-key").properties("example.com/path")
        request = op.call_args.args[0]
        self.assertEqual(request.method, "GET")
        self.assertTrue(request.full_url.endswith("site_id=example.com%2Fpath"))

    def test_api_failure_returns_nonzero_without_success_message(self):
        args = ["plausible-admin", "--url", "https://analytics.test", "--api-key", "test-key",
                "properties", "add", "pixfy.io", "stage"]
        output, errors = io.StringIO(), io.StringIO()
        with patch("sys.argv", args), patch.object(
            admin.Client, "add_properties", side_effect=admin.APIError("HTTP 404: missing route")
        ), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(admin.main(), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("HTTP 404", errors.getvalue())

    def test_existing_event_commands_still_parse(self):
        args = admin.build_parser().parse_args(["events", "add", "pixfy.io", "Signup"])
        self.assertEqual((args.command, args.event_command, args.names), ("events", "add", ["Signup"]))


if __name__ == "__main__":
    unittest.main()
