# Traffic quality

Every session is classified when it starts (`Plausible.Ingestion.Traffic`), and the class is
stored on the session and its events (`traffic`: 0 human, 1 suspicious, 2 bot) along with the
reasons (`sessions_v2.traffic_reasons`). Dashboards and the Stats API count humans unless asked
otherwise. Nothing is dropped.

## Signals

| Effect | Reasons |
| --- | --- |
| Bot on its own | `bot_ua`, `headless_ua`, `webdriver`, `automation_globals` |
| Suspicious on its own | `forged_search_referrer` (http or query-string Google referrer), `oneshot_farm` |
| Weak, two make a session suspicious | `unknown_ua`, `no_device`, `datacenter_ip`, `search_ref_datacenter`, `outdated_browser`, `no_referrer`, `zero_window`, `no_languages` |
| Evidence only | `no_sec_fetch`, `no_client_hints` |

The descriptions live in `Plausible.TrafficQuality.reason_info/1`.

`oneshot_farm` is set afterwards by `Plausible.Workers.TrafficFarms` (hourly): one network
(`sessions_v2.network`, a daily-salted hash of the /24 or /48) sending a site 30+ visitors on one
UTC day, 90%+ of whom view one page and never interact.

## Page and API

`/<domain>/traffic` (owners and admins) shows, for 7, 28 or 90 UTC days:

- yesterday's alerts (`Plausible.TrafficAlerts`): bot and datacenter shares, forged search
  referrers, visitor farms, human drops and spikes, non-human surges, referrer surges and edge
  crawler changes, each against the 14 days before
- sessions and pageviews per class by day, the reasons and how many sessions each touched
- crawler requests at the Cloudflare edge ([edge-requests.md](edge-requests.md))
- a written summary on request (below)

The same facts as JSON: `GET /api/v1/admin/traffic?site_id=<domain>&days=1..90` (default 7),
with the admin API key. The MCP tool `traffic_quality` calls it ([mcp.md](mcp.md)).

## Written summary

With `ANTHROPIC_API_KEY` set, the page has a "Write summary" button (English or Chinese).
`Plausible.TrafficReport` sends the JSON above plus precomputed shares to Claude
(`claude-sonnet-5-5`) and tells it to quote only those figures. Numbers in the answer that don't
appear in the facts are listed under the summary as unverified. Each click is one API call;
nothing is stored.
