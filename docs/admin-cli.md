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

Use `bin/plausible-admin properties discover pixfy.io` to list unconfigured property
keys recorded during the past six months (up to 300). Review these names and pass
them together to `properties add`. Discovery does not change settings.
The CLI identifies itself as `PlausibleAdmin/1.0` for proxies and access logs.

## Visit paths (read-only)

`paths` reconstructs anonymized per-visit event sequences from ClickHouse, for
questions the Stats API cannot answer (what visitors did before or after a step):

```sh
bin/plausible-admin paths scribix.io                                   # most common paths, last 30 days
bin/plausible-admin paths scribix.io --mode sessions --contains checkout_click,upgrade_cta_shown --props reason,tier
bin/plausible-admin paths scribix.io --mode next --step transcribe_success
bin/plausible-admin paths scribix.io --mode prev --step /pricing --from 2026-09-01 --to 2026-09-30 --json
```

The route is `GET /api/v1/admin/paths?site_id=...&mode=top|sessions|next|prev`
with optional `from`, `to` (site-timezone dates, at most 90 days), `contains`
(visits with any of these events), `props`, `step` (required for next/prev; an
event name or a page path) and `limit` (1–500, default 50). Owners and admins
only; it never writes data.

Each step is a normalized page path or an event name. Locale prefixes are
dropped (`/ja/pricing` → `/pricing`), UUIDs, numbers and long tokens become
`:id`, query strings are removed and consecutive repeats collapse. Event props
are appended only when requested and only for short enum-like values
(`upgrade_cta_shown(reason=quota)`); identifier, URL, name, message and other
free-text keys are rejected. Responses contain dates, source, device class and
step offsets in seconds, never session or visitor IDs. In next/prev mode a bare
event name also matches its labels with props.

Limits: 30 steps per visit and 500,000 scanned events (`truncated: true` when
reached). Visits cannot be linked across days because visitor hashes rotate
daily.
