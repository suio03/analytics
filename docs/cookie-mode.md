# Cookie mode

The tracker (`/js/script.js` and every variant) keeps a random visitor id in a first-party cookie `rc_vid` on the site's root domain (shared by its subdomains, 400 days) and mirrors it in `localStorage`. It is sent as `v` with every event, including pageleave.

When an event carries a valid `v` (`[A-Za-z0-9_-]{8,64}`), the server derives the visitor id from it, the site domain and the root domain, keyed with a fixed secret derived from `SECRET_KEY_BASE` (`Plausible.Ingestion.Event`). Without `v` it falls back to the cookieless hash of IP + user agent with the daily rotating salt. So:

- One person stays one visitor across days, IP changes and network switches, and people behind one NAT are no longer merged.
- Multi-day unique visitor counts drop toward real people. Data from before 2026-11-13 is unchanged.
- Safari (ITP) caps script-set cookies and `localStorage` at 7 days without a visit, so Safari visitors who return after longer count as new.
- Rotating `SECRET_KEY_BASE` makes everyone a new visitor.

## Turning it off on one site

Add `data-cookieless` to the script tag. Nothing is stored and no `v` is sent:

```html
<script defer data-domain="example.com" data-cookieless src="https://actone.app/js/script.js"></script>
```

## Linking server events and checkouts

`window.plausible.visitorId` holds the id once the script has loaded (`null` with `data-cookieless`). Pass it into the checkout (e.g. Paddle `custom_data`) and send it back as `v` on server-side events (such as a webhook's purchase event) so they join the visitor's own sessions instead of counting as a separate visitor.
