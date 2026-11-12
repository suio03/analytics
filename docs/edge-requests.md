# Crawlers at the edge

The tracker only sees visitors that run JavaScript. AI crawlers, link previews, SEO tools and
scrapers behind a browser user agent only show up in the CDN's logs. `Plausible.EdgeRequests`
reads Cloudflare's GraphQL analytics (`httpRequestsAdaptiveGroups`, free plan, last 30 days) and
keeps daily counts in Postgres (`edge_requests`), so they outlive Cloudflare's retention.

- Counts are Cloudflare's sampled estimates of HTML responses to real clients
  (`requestSource: eyeball`) on the site's host and its `www.` twin, per UTC day.
- A site is matched to the zone whose name is the longest suffix of its domain.
- The top 10,000 user agents per day are classified by `Plausible.EdgeRequests.Agents` into
  AI training, AI assistants & AI search, search, social, SEO, monitoring, other bots, fake
  browsers (unidentifiable or outdated desktop Chrome) and browsers. The unlisted tail counts as
  browsers.
- `Plausible.Workers.SyncEdgeRequests` re-syncs the last 3 days every 6 hours.

## Setup

Off unless `CLOUDFLARE_API_TOKEN` is set. Create a token with **Zone → Zone → Read** and
**Zone → Analytics → Read** for the zones to include, and set it in the app's environment.
Sites without a matching zone are skipped.
