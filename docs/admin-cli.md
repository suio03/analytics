# Self-hosted event goals CLI

This fork exposes a small authenticated API for managing custom event goals across all sites available to one Plausible account. It uses a normal account API key, so one key works across every site that account owns or administers.

Create one API key in **Settings → API Keys**, then configure the CLI once:

```sh
export PLAUSIBLE_URL="https://analytics.example.com"
export PLAUSIBLE_API_KEY="your-api-key"
```

Run the CLI from this repository:

```sh
bin/plausible-admin sites
bin/plausible-admin events list example.com
bin/plausible-admin events add example.com Signup "Start checkout"
bin/plausible-admin events remove example.com Signup
bin/plausible-admin events sync example.com events.txt
```

`events.txt` contains one event name per line. A JSON array (or an object with an `events` array) is also accepted when the filename ends in `.json`.

Sync is additive by default. Add `--prune` only when the file should become the exact custom-event list:

```sh
bin/plausible-admin events sync example.com events.json --prune
```

Pruning never removes pageview goals. Requests are authorized with the API key's account membership; viewers cannot change goals.

## Dashboard Custom Properties

List configured properties or add several names in one API request:

```sh
bin/plausible-admin properties list pixfy.io
bin/plausible-admin properties add pixfy.io outcome stage error_category
```

This enables property names in dashboard settings. It does **not** send analytics
events or property values. Existing recorded values remain available; no event
replay is required. Adds preserve existing properties, trim names and ignore
duplicates, so re-running the command is safe. The output includes newly added
names and the complete configured list. Owners and admins may use these commands;
viewer keys cannot access them.

The server must include the new authenticated routes before using these commands:
`GET /api/v1/admin/properties?site_id=...` and
`POST /api/v1/admin/properties` with
`{"site_id":"pixfy.io","properties":["outcome","stage","error_category"]}`.
The same account API key and URL used for event goals are used for properties.
The add request is atomic; invalid names or exceeding the 300-property site limit
leave existing settings unchanged. Each name must contain 1–300 characters after
trimming. Property removal and replacement are deliberately not part of this command.

CLI regression tests: `python3 -m unittest discover -s test/cli -p 'test_*.py'`.
API tests: `MIX_ENV=ce_test mix test test/plausible_web/controllers/api/admin_events_controller_test.exs`.
