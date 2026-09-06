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
