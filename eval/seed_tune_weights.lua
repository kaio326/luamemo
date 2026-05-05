-- One-shot seeder for tune_weights smoke runs. Inserts 30 distinct
-- memos under scope "tune_test" so the leave-one-out sweep has enough
-- material. Idempotent: clears the scope first.

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local db_shim = require("_smoke_lapis_db")
db_shim._connect({
    host     = os.getenv("PGHOST") or "127.0.0.1",
    port     = tonumber(os.getenv("PGPORT") or "5432"),
    database = os.getenv("PGDATABASE") or "lm_bruteforce_test",
    user     = os.getenv("PGUSER") or "postgres",
    password = os.getenv("PGPASSWORD") or "postgres",
})
package.loaded["lapis.db"] = db_shim

local memory = require("lapis_memory")
memory.setup({
    db_table       = "lapis_memory",
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "auto",
    default_scope  = "tune_test",
    auth_fn        = function() return true end,
})

db_shim.query("DELETE FROM lapis_memory WHERE scope = 'tune_test'")

local memos = {
    { "Docker compose deployment", "Run docker compose up -d to start the application stack on production." },
    { "Postgres backup with pg_dump", "Schedule pg_dump nightly and upload the dump to S3 with versioning enabled." },
    { "Cache invalidation profile", "Flush profile_cache after any profile update so stale data is not served." },
    { "JWT vs server sessions", "We use server sessions for CSRF safety and easier revocation than JWT." },
    { "T2125 expense categories CRA", "Meals deductible at 50%, motor vehicle by km log, home office by sqft." },
    { "Nginx CSP nonce header", "Set Content-Security-Policy script-src self with per-request nonce in before_filter." },
    { "Bcrypt cost factor 12", "Use BCRYPT_ROUNDS=12 from helpers.constants for password hashing." },
    { "Login brute-force rate limit", "ngx.shared.login_attempts tracks failures per IP across workers, 5 fails = 429." },
    { "OpenResty shared dict size", "Declare lua_shared_dict profile_cache 10m in nginx.conf for cross-worker cache." },
    { "Lapis migration idempotent", "All db_migration.sql operations must use IF EXISTS / IF NOT EXISTS guards." },
    { "Email plus addressing tag", "user+tag@domain delivered to user, tag becomes auto-applied label if matching." },
    { "SMTP STARTTLS port 587", "Connect on 587, issue STARTTLS, then AUTH LOGIN with base64 credentials." },
    { "CRA T4127 payroll deductions", "Annualize gross, compute brackets, de-annualize for per-period tax." },
    { "CPP YMPE 2025 ceiling", "First ceiling YMPE 71300, second ceiling YAMPE 81200 for CPP2 contributions." },
    { "EI insurable earnings 2025", "Maximum insurable earnings 65700, employee rate 1.64%, employer 1.4x." },
    { "Quebec QPIP EI reduction", "Quebec workers pay reduced EI 1.32% because QPIP covers parental leave." },
    { "Ontario surtax brackets", "Ontario applies 20% and 36% surtax on top of provincial tax over thresholds." },
    { "Hybrid search vector + FTS", "Combine pgvector cosine with tsvector ranking using configured weights." },
    { "Brute-force backend no pgvector", "REAL[] column with Lua cosine when extension absent, autodetect on setup." },
    { "Web UI memory inspector", "lapis_memory.web mounts admin routes for browsing scopes and tags." },
    { "Decay half-life days", "Score decays as exp(-ln2 * age_days / half_life), default half_life 30 days." },
    { "Dedup near-duplicate merge", "On write, search top-3 in scope; if cosine > 0.92 merge bodies and bump." },
    { "Summarizer rollup oldest", "Run summarizer cycle daily, rolls oldest N rows in scope into one summary." },
    { "MCP server stdio JSONRPC", "lapis-memory MCP exposes write/search/get over JSONRPC stdio for agent tools." },
    { "Importance scoring 1 to 5", "Importance multiplies decayed score; user can override via metadata.importance." },
    { "ngx.shared scopes per worker", "shared dicts are shared across all OpenResty worker processes via mmap." },
    { "Lapis route module pattern", "Group routes per file under routes/ and require them from app.lua." },
    { "etlua content_for inner", "Layouts wrap views via content_for inner; rendered with self render call." },
    { "OWASP top 10 hardening", "Validate inputs at boundaries, escape outputs, parametrize SQL, set headers." },
    { "Backup script all clients", "scripts/backup_all_clients.sh iterates databases and pg_dumps each one." },
}

for _, m in ipairs(memos) do
    local row, err = memory.write({
        scope = "tune_test",
        kind  = "fact",
        title = m[1],
        body  = m[2],
        dedup_strategy = "append",  -- keep all rows, this is a seed
    })
    if not row then error("seed insert failed: " .. tostring(err)) end
end

local n = db_shim.query("SELECT count(*) AS c FROM lapis_memory WHERE scope = 'tune_test'")
print("seeded tune_test rows:", n[1].c)
