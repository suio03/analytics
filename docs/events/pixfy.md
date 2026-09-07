# Pixfy event goals

`pixfy.json` contains the 42 event names with active emitters in the Pixfy working tree as of 2026-09-07. It is an additive goal configuration, not a count of unique funnel steps.

```sh
bin/plausible-admin events sync pixfy.io docs/events/pixfy.json
```

Do not use `--prune` for this migration: retain existing goal IDs and historical reporting. Pixfy tracking code was deployed on 2026-09-07 in commit `e57ecae` ([successful CI run](https://github.com/suio03/pixfy/actions/runs/34125507845)). Read-only production checks returned 200 for the homepage, Chinese pricing and Studio continuation pages; loaded scripts contain the new login event names. Creating goals alone does not produce conversions, and these checks do not claim end-to-end login/payment event receipt.

## New goals

- `signin_oauth_redirect`: redirect to the OAuth provider; not completed login.
- `signin_completed`: authenticated session confirmed after a same-tab sign-in attempt.
- `checkout_entitlement_observed`: account access observed on payment return; not proof of a new payment.

## Historical goals

Keep `signin_success_from_modal`, `checkout_start_click`, `checkout_redirect_started`, and `checkout_return_success_confirmed` for historical queries. Their emitters are retired in the pending Pixfy changes. Do not combine their historical counts with the replacement events.

Other legacy/unwired goals remain untouched. New additions are limited to names actually emitted by the audited code; declarations alone are not evidence of a working event.

## Analysis rules

- Login: `signin_modal_open` → `signin_oauth_redirect` → `signin_completed`. Login is not necessarily account registration.
- Checkout: `subscribe_cta_click` → `checkout_initiated` → `checkout_session_create_success` → `checkout_redirect`. Separate client/server observations using `surface`; do not sum them.
- Payment and entitlement: inspect webhook `checkout_session_completed`, `subscription_payment_succeeded` and `entitlement_grant_success` separately. Reconcile using checkout/payment IDs, deduplicate webhook retries, and distinguish renewals from first purchases. Server events are not automatically the same Plausible visitor as the browser.
- Continuation uses `studio_action` with `action=result_continue`; do not create a standalone `result_continue` event goal. Break down by `source` and `stage`.
- Generation failures retain `error_code` and add `error_category`; these are properties, not separate event goals.
- The separate analysis client in the `tracking` repository has its own query configuration; this goal-management sync does not edit that repository or create saved dashboard funnels.

Goal creation and a subsequent GET verified all 42 active events exist, while preserving all previous IDs. The adjacent sync result records the changes. No synthetic conversion events were sent.
