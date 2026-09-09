# Site transactions

The private `/:domain/transactions` page reads a PostgreSQL payment ledger. It is independent of Plausible goals and the application's own legacy Paddle billing integration.

## Connect a provider

1. Open the site's **Transactions → Payment connections** (also linked in Settings → Integrations).
2. Select live or sandbox. Copy the new connection's webhook URL to the provider dashboard and obtain that destination's signing secret.
3. Enter the server API key, signing secret and exact product IDs belonging to this site. Paddle Billing uses `pro_…`; Creem uses `prod_…`. Keep the form open until saved so the URL stays the same.
4. Save the form. A historical synchronization job is queued. The connected-account section displays the saved webhook URL and last successful sync/error.
5. Enable the webhook events listed on the page. Use **Sync now** to refresh manually.

Paddle requires a Billing API key with transaction read access and permission to read the related customer, address and adjustment information. This does not reuse the application's Paddle Classic subscription credentials. Creem keys must match the selected environment.

Each site can have one connection per provider/environment. Credentials can be rotated by resubmitting that provider/environment; blank secrets retain existing values. To add products, use **Add product IDs → Add products and sync** under the relevant connected account. Enter only the new IDs, separated by commas or new lines. Saving merges and deduplicates IDs, keeps the existing products, credentials and webhook URL, and queues a historical sync for the expanded mapping. Existing product IDs cannot be removed through this form. Additions are serialized with other saves and imports to avoid lost updates. A mixed basket with products outside the mapping is excluded in full, not attributed in full to multiple sites.

## Data and semantics

- List: customer/transaction search, status, product, provider, purchase type, currency, environment, creation-date range and pagination. Detail pages have stable site-scoped URLs.
- Amounts are integer minor units and are formatted according to currency precision. No currency conversion is performed. Summary amounts are grouped by currency and follow all active filters, including the transaction's **creation date** in the site's timezone (not a settlement-date accounting report).
- Collected amounts come from captured Paddle payments or Creem's `amount_paid`. Missing values remain null. Unpaid orders do not imply revenue.
- Paddle fee and net earnings use provider totals after adjustments when present. Only approved refund adjustments affect refunded status. Pending approval is not a completed refund. Chargebacks are shown as disputed.
- Creem's transaction API does not report payment method, captured timestamp, fees or earnings. These remain `—`. It does not list abandoned checkouts, so historical Creem incomplete checkouts cannot be imported by this integration.
- Paddle identifies renewals using transaction origin. Creem subscription transactions without first-payment evidence are deliberately labeled **Subscription (unspecified)**, rather than guessing first purchase/renewal.
- Activity lists received provider events. Historic imports do not fabricate a historic webhook timeline. Creem links to the provider dashboard; Paddle links to the specific transaction.
- Email and payment details are limited to authenticated site owners, admins and super admins. Viewers, public dashboards and shared links cannot access the payment routes. Responses use `private, no-store`. This version uses those existing roles rather than introducing a new membership role.

## Synchronization

`Plausible.Workers.SyncPayments` runs in the `payments` Oban queue. It reads all pages from Paddle, or all pages for each mapped Creem product, and enriches Creem customer information. Pagination stays on hard-coded provider hosts. The API adapter only performs GET requests.

A transaction unique index on `(integration_id, external_id)` prevents duplicate income. Webhook receipt IDs are unique per integration, and receipt insertion plus job enqueue happen in one transaction. The receiver verifies the exact raw request bytes with the provider signing secret (Paddle also enforces its five-second signature timestamp tolerance).

Webhooks queue a fresh provider snapshot instead of overwriting state with possibly stale event payloads. Integration row locking serializes snapshots across workers; failed imports roll back the entire snapshot and leave existing records intact. Oban retries failures up to five attempts. A cron job queues reconciliation every 30 minutes when background scheduling is enabled. No refund, subscription cancellation or charge operation is performed.

This first version intentionally does a full snapshot for reliability at small transaction volumes. For large accounts, add provider-specific incremental sync/checkpoints and customer caching before shortening the schedule. Long imports hold a database connection; failed/limited requests are visible as sync errors.

## Deployment and verification

Run the normal PostgreSQL migration and asset deployment steps before starting the new application version:

```sh
mix ecto.migrate
mix assets.deploy
```

Keep the existing vault key stable: payment credentials use the application's Cloak vault, also used by TOTP. Credentials and provider webhook payload fields are filtered from Phoenix request logs. No API key goes to dashboard JavaScript or HTML.

Focused tests (use the environment appropriate for this checkout):

```sh
MIX_ENV=ce_test mix test test/plausible/payments \
  test/plausible/payments_test.exs \
  test/plausible_web/controllers/payments_controller_test.exs \
  test/plausible_web/controllers/api/payment_webhook_controller_test.exs \
  test/plausible_web/plugs/authorize_site_access_test.exs
```

Tests cover amounts/refunds, currency boundaries, signature tampering and replay, encrypted storage, site/environment isolation, repeated webhooks, provider pagination, credential rotation, and failed-import rollback. Provider tests use HTTP fixtures; live credentials and real provider delivery still require acceptance in the deployed environment.
