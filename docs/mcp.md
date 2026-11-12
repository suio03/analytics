# MCP server

`bin/recount-mcp` is a stdio MCP server that lets an AI agent (Claude Code, Claude Desktop,
Cursor…) read Recount directly. It wraps the Stats API v2 and the admin API; it holds no logic
of its own. It needs `uv` (dependencies are declared inline and installed on first run).

| Tool | Route |
| --- | --- |
| `list_sites` | `GET /api/v1/admin/sites` |
| `query_stats` | `POST /api/v2/query` (human traffic only, like the dashboard default) |
| `traffic_quality` | `GET /api/v1/admin/traffic` (see [traffic-quality.md](traffic-quality.md)) |
| `visit_paths` | `GET /api/v1/admin/paths` |
| `list_replays` | `GET /api/v1/admin/replays` |
| `list_goals` | `GET /api/v1/admin/events` |
| `list_properties` | `GET /api/v1/admin/properties` |
| `add_goals`, `add_properties` | `POST` to the same routes, only with `RECOUNT_MCP_WRITE=1` |

It is read-only unless `RECOUNT_MCP_WRITE=1`; the write tools are additive.

## Setup

Use the same API key as `bin/plausible-admin` (owner or admin of the sites it should read).

Claude Code, for one user:

```sh
claude mcp add recount --scope user \
  --env PLAUSIBLE_URL=https://actone.app \
  --env PLAUSIBLE_API_KEY=<key> \
  -- ~/Documents/side-projects/analytics/bin/recount-mcp
```

Any other client takes the same command and env in its JSON config:

```json
{
  "mcpServers": {
    "recount": {
      "command": "/path/to/analytics/bin/recount-mcp",
      "env": { "PLAUSIBLE_URL": "https://actone.app", "PLAUSIBLE_API_KEY": "<key>" }
    }
  }
}
```

`uv` caches the environment, so only the first start downloads packages. The script pins
`mcp<2` because version 2 renamed the server API.
