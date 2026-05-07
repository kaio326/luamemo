-- Phase 10.3 runner: re-embed every row in `lm_memories` against the
-- currently-configured embedder. Use this when:
--   * you switched embedders (hash → ollama, openai → voyage, etc.)
--   * you increased / decreased `embed_dim`
--   * a model was updated server-side and you want to refresh vectors
--
-- Safety properties:
--   * Idempotent: rows whose `metadata->>'embedding_fingerprint'` matches
--     the current `md5(title|body) || ':' || dim` are skipped.
--   * Non-disruptive: the `updated_at` touch trigger is disabled for the
--     duration so re-embedding does not shift recency-decay rankings.
--   * Batched: configurable `--batch` size; processes rows in id order.
--   * --dry-run reports without writing.
--
-- LIMITATIONS:
--   * pgvector backend stores embeddings in `VECTOR(N)` columns where N is
--     fixed at table creation. If you change `embed_dim`, drop and re-create
--     the table or column first; this runner cannot resize the column.
--     The brute-force backend uses `REAL[]` which accepts new dims directly.
--
-- Usage:
--   PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=mydb \
--     lua5.1 eval/reembed.lua [--scope <name>] [--batch <N>] [--dry-run]
--
--   --scope <name>   restrict to one scope (default: all scopes)
--   --batch <N>      rows per batch (default: 100)
--   --dry-run        report counts and the first N targets, write nothing

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

-- luamemo.db creates a pgmoon connection automatically from
-- PGHOST / PGDATABASE / PGUSER / PGPASSWORD env vars when outside OpenResty.

-- --- arg parsing ----------------------------------------------------------
local args = { scope = nil, batch = 100, dry_run = false }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--scope" then args.scope = arg[i + 1]; i = i + 2
        elseif a == "--batch" then args.batch = tonumber(arg[i + 1]); i = i + 2
        elseif a == "--dry-run" then args.dry_run = true; i = i + 1
        else io.stderr:write("unknown arg: " .. tostring(a) .. "\n"); os.exit(2) end
    end
end

local memory = require("luamemo")
local db     = require("luamemo.db")
local embed  = require("luamemo.embed")

memory.setup({
    db_table         = "lm_memories",
    embedder_local   = os.getenv("EMBEDDER_LOCAL") or "hash",
    embedder_url     = os.getenv("EMBEDDER_URL"),
    embedder_adapter = os.getenv("EMBEDDER_ADAPTER") or "generic",
    embedder_model   = os.getenv("EMBEDDER_MODEL"),
    embed_dim        = tonumber(os.getenv("EMBED_DIM") or "384"),
    backend          = "auto",
    auth_fn          = function() return true end,
    -- The probe still runs for non-hash embedders — that's exactly what
    -- we want before launching a long re-embed.
})

local cfg_dim   = tonumber(os.getenv("EMBED_DIM") or "384")
local backend   = memory.store.backend()
local table_nm  = "lm_memories"

local where = "TRUE"
if args.scope then
    where = "scope = " .. db.escape_literal(args.scope)
end

-- Count target rows up-front for progress reporting.
local count_row = db.query(("SELECT count(*) AS n FROM %s WHERE %s")
    :format(table_nm, where))[1]
local total = tonumber(count_row.n)
print(string.format("backend=%s  embed_dim=%d  scope=%s  total_rows=%d  batch=%d  dry_run=%s",
    backend, cfg_dim, args.scope or "<all>", total, args.batch, tostring(args.dry_run)))

if total == 0 then
    print("nothing to do")
    os.exit(0)
end

-- Disable the updated_at touch trigger so re-embedding does not shift
-- recency rankings. Re-enabled in the cleanup block at the end.
local trigger_disabled = false
if not args.dry_run then
    local ok = pcall(function()
        db.query("ALTER TABLE " .. table_nm ..
                 " DISABLE TRIGGER lm_memories_touch_updated_at_trg")
    end)
    trigger_disabled = ok
    if ok then print("(updated_at trigger disabled for the duration)") end
end

local function reenable_trigger()
    if trigger_disabled then
        pcall(function()
            db.query("ALTER TABLE " .. table_nm ..
                     " ENABLE TRIGGER lm_memories_touch_updated_at_trg")
        end)
    end
end

-- --- main loop ------------------------------------------------------------
local last_id = 0
local processed, skipped, embedded, errored = 0, 0, 0, 0

while true do
    local sql = ([[
        SELECT id, scope, title, body,
               metadata->>'embedding_fingerprint' AS fp,
               COALESCE(array_length(embedding, 1), 0) AS cur_dim,
               md5(coalesce(title,'') || '|' || coalesce(body,'')) AS hash
        FROM %s
        WHERE %s AND id > %d
        ORDER BY id
        LIMIT %d
    ]]):format(table_nm, where, last_id, args.batch)

    local rows = db.query(sql)
    if not rows or #rows == 0 then break end

    for _, r in ipairs(rows) do
        last_id = tonumber(r.id)
        processed = processed + 1
        local want_fp = r.hash .. ":" .. cfg_dim

        if r.fp == want_fp and tonumber(r.cur_dim) == cfg_dim then
            skipped = skipped + 1
        else
            local txt = (r.title or "") .. " " .. (r.body or "")
            local vec, err = embed.embed(txt)
            if not vec then
                errored = errored + 1
                io.stderr:write(("id=%d embed failed: %s\n"):format(r.id, tostring(err)))
            elseif args.dry_run then
                embedded = embedded + 1   -- counted as "would update"
                if embedded <= 5 then
                    print(("  would re-embed id=%d scope=%s title=%q")
                        :format(r.id, r.scope, (r.title or ""):sub(1, 40)))
                end
            else
                local lit = (backend == "bruteforce")
                    and embed.to_pg_array(vec)
                    or  embed.to_pg_literal(vec)
                local upd = ([[
                    UPDATE %s
                       SET embedding = %s,
                           metadata  = jsonb_set(
                               coalesce(metadata, '{}'::jsonb),
                               '{embedding_fingerprint}',
                               to_jsonb(%s::text))
                     WHERE id = %d
                ]]):format(table_nm, lit,
                           db.escape_literal(want_fp),
                           tonumber(r.id))
                local ok2, err2 = pcall(db.query, upd)
                if ok2 then
                    embedded = embedded + 1
                else
                    errored = errored + 1
                    io.stderr:write(("id=%d update failed: %s\n")
                        :format(r.id, tostring(err2)))
                end
            end
        end
    end

    io.write(("\rprocessed=%d  embedded=%d  skipped=%d  errored=%d")
        :format(processed, embedded, skipped, errored))
    io.flush()
end

reenable_trigger()
io.write("\n")
print(("done: processed=%d  embedded=%d  skipped=%d  errored=%d")
    :format(processed, embedded, skipped, errored))

if errored > 0 then os.exit(1) end
