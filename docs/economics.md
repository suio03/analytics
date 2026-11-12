# Site economics

The private `/:domain/economics` page shows what a site's free users cost against what its sign-ups pay. The site's own app computes the report. This page stores where to fetch it, fetches it on every open, and renders it. Nothing is stored here except the endpoint.

## Connect

1. In the app, set a long random bearer token (Tapemoon: Worker secret `ECONOMICS_TOKEN`, endpoint `GET /api/ops/economics`).
2. Open **Economics → Endpoint** and enter the https URL and the token. The token is encrypted with the application's Cloak vault, as payment credentials are, and is sent only from the server. Leave the token blank to keep the saved one.

Access matches Transactions: site owners, admins and super admins. Responses are `private, no-store`.

## Who computes what

The app exports facts: its accounts, what each one cost and what they paid. Only the app knows what a call cost and whether its account had paid by then, so that stays there. This page does all the reporting: local days and weeks in the site's timezone, the window, first-touch source groups, the 30-day cohort window and payback (`lib/plausible/economics/report.ex`). Changing the report never needs a change in the apps; only a new kind of fact does.

## Export format (format 2)

`GET <url>?days=N&since=<unix seconds>&format=2` with `Authorization: Bearer <token>`. `since` is the first moment of the window's first local day; return everything from then on (cap it at about 200 days back). `days` is for format 1 apps. JSON:

- `format`: `2`, `generatedAt` (ISO time), `notes`: what the app's cost does and doesn't include (strings, shown under the tables)
- `users`: accounts created since `since`: `id`, `at` (unix seconds), `guest` (anonymous account, counted in cost but not as a sign-up), first touch `source` (utm_source / ?ref=), `medium`, `campaign`, `referrer` (host), `landing`, `tracked` (`false` for accounts from before the app recorded first touches), `platform` (`web`, `ios`, `android`, or null)
- `costs`: model cost since `since` in 15-minute buckets: `user` (null when the call has no account), `at` (bucket start), `free` (USD spent while the account had not paid yet), `paid` (USD spent after its first paid order)
- `orders`: paid orders since `since`: `user`, `at`, `usd` (before payment fees), `first` (the account's first paid order), `sku`
- `payers` (optional): every account that has ever paid, with lifetime totals: `id`, `email`, `at` (sign-up), `source`, `referrer`, `tracked`, `platform`, `signupCountry` (request country at sign-up), `billingCountry` (from the payment provider), `orders` and `usd` (paid orders), `refunds` and `refundedUsd`, `firstPaidAt`, `lastPaidAt`, `lastSku`, `plan` (current plan sku or null), `credits` (`bought`, `granted` free, `used`, `left` usable now), `costUsd` (all model cost), `jobs`, `lastActiveAt`
- `freeQuotas` (optional): the app's free daily quotas, per UTC day, computed with the same rules the app enforces: `quotas` (`key`, `label`, `unit` `usd` or `count`, `limit`) and `days` for the last 7 UTC days (`day` `YYYY-MM-DD`, `key`, `used`, `fullAt` the unix second the quota filled or null; days without use can be left out)

Fields beyond these are ignored, so an app can add facts before the page uses them. Add fields; never change what one means.

Source groups: `source` when set; else the referrer, with sign-in redirects (`accounts.*`, `appleid.apple.com`) as direct, any `google.` host as `google`, `*bing.com` as `bing`, other hosts without `www.`; else `(before tracking)` when `tracked` is false, else `(direct or unknown)`.

The window is the last N local days including today (7, 28, 90 or 180; 28 by default). The summary covers the whole window; by-day rows include days with no activity, and today is marked "so far". Weeks start on the local Monday, and a week is full once 30 days have passed since it ended.

## Format 1 (app-computed, deprecated)

An app that ignores `format` and returns `daily`, `weeks` and `sources` is shown as it computed them, in UTC days. Keys: `generatedAt`, `days`, `cohortDays`, `notes`; `daily`: `day`, `signups`, `freeUsd`, `paidUsd`, `orders`, `firstOrders`, `revenue`, newest first; `weeks` and `sources`: `key`, `signups`, `buyers`, `freeUsd`, `revenue`, `freePerSignup`, `revenuePerSignup`, `payback`, weeks also `age`.

## Page

**Free quota today** shows, when the app exports `freeQuotas`, how much of each free daily quota is used in the current UTC day and how long until the 00:00 UTC reset: a bar per quota (amber from 80%, red and "Full" with the time it filled), then the last 7 UTC days with each quota's use and the time it filled. These are UTC days because the app resets its quotas at UTC midnight, unlike the rest of the page.

**Paying users** lists accounts with a paid order in the window (lifetime totals), most paid first: country (billing, else sign-up), source, payments and refunds, credits used and left, model cost and margin (paid minus model cost), days from sign-up to first payment, and last activity. Its tiles: paying users and how many paid for the first time, paid per user, repeat buyers (two or more payments), total margin and unused credits. The section shows only when the app exports `payers`. Emails are shown, so the page stays owners and admins only.

Payback is colored red below 1× and amber below 3×, only for weeks that have had their full window and sources with at least 10 sign-ups.

Sections (summary, by source, by sign-up week, by day) can be reordered by dragging the handle beside each heading, or by focusing it and pressing the arrow keys. The order is kept in the viewer's browser (`localStorage`, key `economics-section-order`) and is the same on every site.
