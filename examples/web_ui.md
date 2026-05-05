# Web UI

`lapis-memory` ships a self-contained, server-rendered web browser at
`/memory/ui` (configurable). It's the fastest way to inspect, search,
edit, and delete stored memories without dropping into `psql`.

## Mount

```lua
local lapis  = require("lapis")
local memory = require("lapis_memory")
local app    = lapis.Application()

memory.setup({ ... })                              -- as usual
memory.routes.register(app, { prefix = "/api/memory" })
memory.web.register(app, { prefix = "/memory/ui",  -- defaults shown
                           per_page = 25 })
```

`memory.web` reuses `cfg.auth_fn` and `cfg.before_request` — whatever
gates the JSON API also gates the UI. There's no separate session.

## Pages

| Route | What |
|---|---|
| `GET /memory/ui` | Paginated list. `?q=` runs hybrid search; `?scope=` and `?kind=` filter the browse. |
| `GET /memory/ui/:id` | Detail view + inline edit form + delete button. |
| `POST /memory/ui/:id/update` | Save edits. CSRF-protected. |
| `POST /memory/ui/:id/delete` | Delete. CSRF-protected, JS confirm prompt. |

The list shows `id`, `scope`, `kind`, title, body preview, importance,
the decay-adjusted **effective weight**, and the `updated_at` timestamp
so you can spot rows that are about to fall below your summarisation
threshold.

## CSRF

The UI uses a **double-submit cookie**. The first GET on the detail page
sets `lm_csrf=<random hex>`. Every form on that page includes
`<input type="hidden" name="csrf" value="...">`. POST handlers compare
the cookie to the form field and refuse the request on mismatch.

If `resty.random` is loaded (the default under OpenResty), the token is
cryptographically random; otherwise the harness falls back to
`math.random` so unit tests can run on plain Lua.

## QA recipe

After a fresh install (or after upgrading), run:

```bash
# 1. Boot the demo app or your own host app with web.register wired up.
EMBEDDER_URL=... MEMO_TOKEN=... lapis server

# 2. Browse the empty list. Expect: header, "No memories stored yet."
xdg-open http://localhost:8080/memory/ui

# 3. Write a couple of memories via the API or CLI.
memo write --scope demo --kind note --title "Hello" --body "World"
memo write --scope demo --kind decision --title "Pick PG" --body "pgvector beats faiss for our scale"

# 4. Reload the list. Expect both rows; importance=1.00, weight=1.000.

# 5. Filter by scope: visit /memory/ui?scope=demo. Expect 2 rows.

# 6. Search: /memory/ui?q=pgvector. Expect the decision row first.

# 7. Click the decision row. Detail page shows tags=[], metadata={}.
#    Edit the body, change importance to 2.0, save.
#    Expect green "Saved." flash and the new values reflected.

# 8. Provide invalid JSON in the tags field, save.
#    Expect red "invalid tags JSON" flash; the original row is unchanged.

# 9. Delete the row. Confirm the prompt.
#    Expect a redirect to the list and only one row remaining.
```

## Notes & limitations

- The UI is **admin-grade**, not multi-tenant: `auth_fn` is the only
  access boundary; once authenticated, the UI can read and mutate
  every row in the configured table.
- No undo. Deletes are immediate and unrecoverable. If you want a soft
  delete, wrap `memory.delete` at the app level.
- Pagination is hidden when `?q=` is active because hybrid search
  returns a fixed top-N (capped at 100).
- The "effective weight" column is computed in Lua from `updated_at`
  parsed as `YYYY-MM-DD`. It's an approximation suitable for at-a-glance
  triage; the SQL ranker uses second-resolution math.
