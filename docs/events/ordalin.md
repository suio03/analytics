# Ordalin event goals

`ordalin.json` lists the five custom events emitted by the Ordalin working tree as of 2026-10-06 (`src/lib/analytics.ts`; event table in Ordalin `docs/environment.md`).

```sh
bin/plausible-admin events sync ordalin.com docs/events/ordalin.json
bin/plausible-admin properties add ordalin.com tool placement from search query results
```

Goals (IDs 207–211) and the six properties were created on 2026-10-06 and verified with a subsequent list. The tracking code was not yet deployed at that time, so no conversions existed; no synthetic events were sent.

## Analysis rules

- Primary conversion: `Outbound Click`, broken down by `placement` (`profile`, `row`, `task`, `compare`, `editorial`, or page section) and `tool`.
- Progression: `Tool Open` with `from` (page section) and `search` (`yes`/`no`).
- Search quality: `Search` with `results=0` marks searches without a result; `query` is lower-cased and truncated to 100 characters.
- Submission funnel: `Submission Started` → `Submission Sent`.
- `query` is free text; `paths --props` rejects it by design. Use the dashboard breakdown instead.
