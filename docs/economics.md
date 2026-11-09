# Site economics

The private `/:domain/economics` page shows what a site's free users cost against what its sign-ups pay. The site's own app computes the report. This page stores where to fetch it, fetches it on every open, and renders it. Nothing is stored here except the endpoint.

## Connect

1. In the app, set a long random bearer token (Tapemoon: Worker secret `ECONOMICS_TOKEN`, endpoint `GET /api/ops/economics`).
2. Open **Economics → Endpoint** and enter the https URL and the token. The token is encrypted with the application's Cloak vault, as payment credentials are, and is sent only from the server. Leave the token blank to keep the saved one.

Access matches Transactions: site owners, admins and super admins. Responses are `private, no-store`.

## Report format

`GET <url>?days=N` (7–180) with `Authorization: Bearer <token>` returns JSON:

- `generatedAt`, `days`, `cohortDays`, `notes` (list of strings shown under the tables)
- `daily`: `day`, `signups`, `freeUsd`, `paidUsd`, `orders`, `firstOrders`, `revenue`, newest first
- `weeks` (by sign-up week, Monday) and `sources` (by first-touch source): `key`, `signups`, `buyers`, `freeUsd`, `revenue`, `freePerSignup`, `revenuePerSignup`, `payback`; weeks also have `age`, the days the week's last sign-up has had, up to `cohortDays`

Payback is colored red below 1× and amber below 3×, only for weeks that have had their full window and sources with at least 10 sign-ups.
