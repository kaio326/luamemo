-- luamemo.settings
-- Every setting luamemo reads, in one table: its name in .luamemorc and the environment
-- (MEMO_<KEY>), its config key, type, default, range and meaning. luamemo's default
-- config is built from it; the CLI and the MCP server read the environment through it
-- (from_env); `memo config` checks and writes values with it; `memory_status` lists the
-- effective values and where each came from. Settings are changed by people (memo
-- config, or editing .luamemorc) — MCP only reads them.
--
--   settings.LIST                  → { entry, … } in display order
--   settings.get(name)             → the entry of a MEMO_ name or a config key | nil
--   settings.defaults()            → a new config table holding every default
--   settings.parse(entry, text)    → value | nil, err    (type and range checked)
--   settings.format(entry, value)  → the text written to .luamemorc
--   settings.show(entry, value)    → the text shown (a credential masked)
--   settings.from_env(get)         → { key = value }, { problem, … }, { fatal, … }
--   settings.unknown(names)        → { { name, suggestion | retired }, … }
--   settings.env_names()           → the MEMO_ variables set in this process
--   settings.read_file(path)       → { MEMO_NAME = text } from a .luamemorc
--   settings.files(dir)            → the project / user settings files, read
--   settings.load_files(dir)       → for the MCP server: the files into the environment
--   settings.effective(cfg, files, getenv) → { { entry, value, source }, … }
--   settings.view(cfg, files, getenv)      → the same, as shown text (memory_status)
--   settings.plain_credentials(entry, value) → header names holding a plain credential
--
-- Entry: env (MEMO_ name), key (config key — absent for the few settings read straight
-- from the environment), type ("string" | "number" | "integer" | "boolean" | "list" |
-- "json"), default (also luamemo's config default), implied (the value in force when
-- unset that the embedder / module applies itself — shown, never put in the config; a
-- function of the config when it depends on another setting), min / max, values
-- (allowed strings), group, doc, reembed (a change makes stored vectors incomparable
-- with new ones), headers (HTTP headers: a credential is written {secret:NAME}, a vault
-- reference), secret (never shown, never written by memo config), mcp_env (the MCP
-- server needs it: set only in the shell, memo calibrate offers to save it in the
-- project's .luamemorc — a client starts the server without the shell's environment),
-- aliases (older names, still read),
-- strict (an invalid value stops luamemo instead of falling back to the default —
-- failing closed: a mistyped embedder must not write vectors into another embedding
-- space, MEMO_ORG_SHARE=signal must not fall back to sending query text).

local M = {}

local L = {}
local function S(e) L[#L + 1] = e end

-- ── project ─────────────────────────────────────────────────────────────────
S{ env = "MEMO_DB", key = "db", type = "string", group = "project", mcp_env = true,
   doc = "The project's database: a name (a file in ~/.local/share/luamemo) or a path. memo calibrate gives "
      .. "each project its own." }
S{ env = "MEMO_SCOPE", type = "string", group = "project", mcp_env = true,
   doc = "This project's scope: MCP tools, memo write, memo brief and memo sense use it when a call names none." }
S{ env = "MEMO_MCP_TOOLS", type = "string", group = "project", values = { "all", "core" }, default = "all",
   doc = "The tools the MCP server offers: all, or core — brief, search, write, recent, get, update, delete, "
      .. "promote, sense, status, the code map and secret_list / secret_execute: fewer tool descriptions in "
      .. "every session's context. The others stay on memo." }

-- ── embedder ────────────────────────────────────────────────────────────────
S{ env = "MEMO_EMBEDDER", key = "embedder_local", type = "string", group = "embedder",
   implied = function(cfg) if not cfg.embedder_url then return "hash" end end,
   values = { "hash", "gguf_ffi", "hash_learned", "projected" }, reembed = true, mcp_env = true, strict = true,
   doc = "In-process embedder, used when MEMO_EMBEDDER_URL is unset: hash (pure Lua, word-level), gguf_ffi "
      .. "(a GGUF model run through llama.cpp — MEMO_GGUF_MODEL), hash_learned / projected (hash or another "
      .. "base with a projection learned from use; the base unchanged until one is trained)." }
S{ env = "MEMO_EMBEDDER_URL", key = "embedder_url", type = "string", group = "embedder", reembed = true,
   mcp_env = true, doc = "HTTP embedder endpoint; when set, it is used instead of the in-process one." }
S{ env = "MEMO_EMBEDDER_ADAPTER", key = "embedder_adapter", type = "string", default = "generic",
   values = { "generic", "ollama", "openai", "openai_compatible", "tei", "voyage", "cohere", "deepseek",
              "anthropic" },
   group = "embedder", reembed = true, mcp_env = true, strict = true, doc = "Request format of the HTTP embedder." }
S{ env = "MEMO_EMBEDDER_MODEL", key = "embedder_model", type = "string", group = "embedder", reembed = true,
   mcp_env = true, doc = "Model the HTTP embedder is asked for." }
S{ env = "MEMO_GGUF_MODEL", key = "gguf_model", type = "string", group = "embedder", reembed = true,
   mcp_env = true, aliases = { "MEMO_GEMMA_MODEL" },
   doc = "The .gguf model file of the in-process GGUF embedder (MEMO_EMBEDDER=gguf_ffi)." }
S{ env = "MEMO_EMBED_DIM", key = "embed_dim", type = "integer", default = 384, min = 1, group = "embedder",
   reembed = true, mcp_env = true, strict = true, doc = "Vector size the embedder returns." }
S{ env = "MEMO_EMBEDDER_HEADERS", key = "embedder_headers", type = "json", default = {}, headers = true,
   group = "embedder",
   doc = "Extra HTTP headers for the embedder, a JSON object; a credential as {secret:NAME} (memo secret-store)." }
S{ env = "MEMO_EMBEDDER_INPUT_TYPE", key = "embedder_input_type", type = "string", group = "embedder",
   reembed = true, doc = "Input type sent to cohere (default search_document) or voyage (default: none)." }
S{ env = "MEMO_EMBEDDER_NUM_CTX", key = "embedder_num_ctx", type = "integer", min = 1, group = "embedder",
   doc = "Context size asked of an ollama embedder (default: the model's)." }
S{ env = "MEMO_EMBED_TIMEOUT_MS", key = "embed_timeout_ms", type = "integer", default = 30000, min = 1,
   group = "embedder", doc = "Timeout of one embedding request (ms)." }
S{ env = "MEMO_EMBED_MAX_CHARS", key = "embed_max_chars", type = "integer", min = 1, group = "embedder",
   doc = "Longer text is cut to this many characters before embedding (the row is flagged); unset: no limit." }
S{ env = "MEMO_PROJECTED_BASE", key = "projected_base", type = "string", group = "embedder", reembed = true,
   doc = "Base embedder of the projected embedder (hash, gguf_ffi, …)." }
S{ env = "MEMO_GGUF_NCTX", key = "gguf_n_ctx", type = "integer", implied = 2048, min = 1, group = "embedder",
   aliases = { "MEMO_GEMMA_NCTX" }, doc = "Context size of the in-process GGUF embedder." }
S{ env = "MEMO_GGUF_NGL", key = "gguf_n_gpu", type = "integer", implied = 0, min = -1, group = "embedder",
   aliases = { "MEMO_GEMMA_NGL" }, doc = "GPU layers for the GGUF embedder: 0 CPU, N layers, -1 all." }
S{ env = "MEMO_GGUF_SHIM", key = "gguf_shim_path", type = "string", group = "embedder",
   aliases = { "MEMO_GEMMA_SHIM" }, doc = "Path of the built GGUF shim (default: the one next to luamemo)." }
S{ env = "MEMO_CA_FILE", type = "string", group = "embedder", mcp_env = true,
   doc = "A PEM certificate (or CA) trusted for https:// calls besides the system's — a self-hosted service's." }
S{ env = "MEMO_SKIP_EMBED_PROBE", key = "skip_embed_probe", type = "boolean", default = false,
   group = "embedder", doc = "Skip the embedder check at startup." }
S{ env = "MEMO_ENSURE_READY_RETRY_SECS", key = "ensure_ready_retry_secs", type = "integer", default = 10,
   min = 0, group = "embedder",
   doc = "While the embedder is down, retry it at most once per this many seconds (0: on every call)." }

-- ── writes ──────────────────────────────────────────────────────────────────
S{ env = "MEMO_DEFAULT_SCOPE", key = "default_scope", type = "string", default = "global", group = "writes",
   doc = "Scope of a memory written without one (and without MEMO_SCOPE)." }
S{ env = "MEMO_DEFAULT_IMPORTANCE", key = "default_importance", type = "number", default = 1.0, min = 0,
   max = 10, group = "writes", doc = "Importance of a memory written without one (0–10, a ranking weight)." }
S{ env = "MEMO_DEFAULT_DECAY_RATE", key = "default_decay_rate", type = "number", default = 0.0, min = 0,
   max = 1, group = "writes", doc = "Daily decay of a memory written without one (0: none)." }
S{ env = "MEMO_DEDUP_ENABLED", key = "dedup_enabled", type = "boolean", default = true, group = "writes",
   doc = "Check each write for a near-identical memory in its scope." }
S{ env = "MEMO_DEDUP_THRESHOLD", key = "dedup_threshold", type = "number", default = 0.95, min = 0, max = 1,
   group = "writes", doc = "Similarity at which a write counts as a duplicate." }
S{ env = "MEMO_DEDUP_STRATEGY", key = "dedup_strategy", type = "string", default = "update",
   values = { "update", "skip", "append" }, group = "writes",
   doc = "On a duplicate: update (merge into it), skip, or append (keep both)." }
S{ env = "MEMO_DEDUP_CANDIDATE_LIMIT", key = "dedup_candidate_limit", type = "integer", default = 1000, min = 1,
   group = "writes", doc = "Rows a batch write compares against, per scope." }
S{ env = "MEMO_PATTERNS_ENABLED", key = "patterns_enabled", type = "boolean", default = true, group = "writes",
   doc = "Extract first-person preferences (\"I prefer …\") from writes into companion memories." }
S{ env = "MEMO_PATTERNS_MAX_BODY_CHARS", key = "patterns_max_body_chars", type = "integer", default = 5000,
   min = 0, group = "writes", doc = "Longer bodies are not scanned for preferences." }

-- ── search ──────────────────────────────────────────────────────────────────
S{ env = "MEMO_HYBRID_WEIGHTS", key = "hybrid_weights", type = "json", default = { vector = 0.7, fts = 0.3 },
   group = "search", doc = "Blend of the vector and text scores: {\"vector\": …, \"fts\": …}." }
S{ env = "MEMO_OBS_MAX_SLOTS", key = "obs_max_slots", type = "integer", default = 3, min = 0, group = "search",
   doc = "Observations listed after the memories of a search (0: none)." }
S{ env = "MEMO_PERSON_NAME_BOOST", key = "person_name_boost", type = "number", default = 0.15, min = 0,
   group = "search", doc = "Score boost for a memory naming a capitalised name from the query." }
S{ env = "MEMO_PERSON_NAME_BOOST_ENABLED", key = "person_name_boost_enabled", type = "boolean", default = true,
   group = "search", doc = "Apply the name boost." }
S{ env = "MEMO_QUOTED_PHRASE_BOOST", key = "quoted_phrase_boost", type = "number", default = 0.40, min = 0,
   group = "search", doc = "Score boost for a memory containing a quoted phrase of the query verbatim." }
S{ env = "MEMO_QUOTED_PHRASE_BOOST_ENABLED", key = "quoted_phrase_boost_enabled", type = "boolean",
   default = true, group = "search", doc = "Apply the quoted-phrase boost." }
S{ env = "MEMO_TEMPORAL_ALPHA", key = "temporal_alpha", type = "number", default = 0.2, min = 0, max = 1,
   group = "search", doc = "Strength of the time boost for a query naming a time (\"last week\")." }

-- ── rerank ──────────────────────────────────────────────────────────────────
S{ env = "MEMO_RERANK_ENABLED", key = "rerank_enabled", type = "boolean", default = false, group = "rerank",
   doc = "Rerank every search (a call can still turn it off)." }
S{ env = "MEMO_RERANK_ADAPTER", key = "rerank_adapter", type = "string", default = "noop",
   values = { "noop", "ollama", "openai", "cross_encoder", "learned" }, group = "rerank",
   doc = "Reranker: noop (word overlap), ollama, openai, cross_encoder (TEI / Cohere / Jina), learned (from use)." }
S{ env = "MEMO_RERANK_URL", key = "rerank_url", type = "string", group = "rerank", doc = "Reranker endpoint." }
S{ env = "MEMO_RERANK_MODEL", key = "rerank_model", type = "string", group = "rerank", doc = "Reranker model." }
S{ env = "MEMO_RERANK_HEADERS", key = "rerank_headers", type = "json", default = {}, headers = true,
   group = "rerank", doc = "Extra HTTP headers for the reranker, a JSON object; a credential as {secret:NAME}." }
S{ env = "MEMO_RERANK_TIMEOUT_MS", key = "rerank_timeout_ms", type = "integer", default = 30000, min = 1,
   group = "rerank", doc = "Timeout of one rerank request (ms)." }
S{ env = "MEMO_RERANK_TOP_N", key = "rerank_top_n", type = "integer", default = 20, min = 1, group = "rerank",
   doc = "Results the reranker sees per search (a cost cap)." }
S{ env = "MEMO_RERANK_EPSILON", key = "rerank_epsilon", type = "number", default = 0, min = 0, max = 1,
   group = "rerank",
   doc = "learned reranker: chance that a result's score is jittered, so new results still get seen (0: off)." }

-- ── summarizer ──────────────────────────────────────────────────────────────
S{ env = "MEMO_SUMMARIZER_ADAPTER", key = "summarizer_adapter", type = "string", default = "noop",
   values = { "noop", "ollama", "openai" }, group = "summarizer",
   doc = "Summarizer: noop (no model — joins the memories), ollama, openai." }
S{ env = "MEMO_SUMMARIZER_URL", key = "summarizer_url", type = "string", group = "summarizer",
   doc = "Summarizer endpoint." }
S{ env = "MEMO_SUMMARIZER_MODEL", key = "summarizer_model", type = "string", group = "summarizer",
   doc = "Summarizer model." }
S{ env = "MEMO_SUMMARIZER_HEADERS", key = "summarizer_headers", type = "json", default = {}, headers = true,
   group = "summarizer",
   doc = "Extra HTTP headers for the summarizer, a JSON object; a credential as {secret:NAME}." }
S{ env = "MEMO_SUMMARIZER_TIMEOUT_MS", key = "summarizer_timeout_ms", type = "integer", default = 60000,
   min = 1, group = "summarizer", doc = "Timeout of one summarizer request (ms)." }
S{ env = "MEMO_SUMMARIZER_INTERVAL_SECONDS", key = "summarizer_interval_seconds", type = "integer",
   default = 0, min = 0, group = "summarizer",
   doc = "Summarize automatically (alongside the writes' maintenance) at most this often; 0: only on demand." }
S{ env = "MEMO_SUMMARIZER_WEIGHT_THRESHOLD", key = "summarizer_weight_threshold", type = "number",
   default = 0.5, min = 0, group = "summarizer",
   doc = "Memories weighing less than this (importance × decay) are summarized …" }
S{ env = "MEMO_SUMMARIZER_RETENTION_DAYS", key = "summarizer_retention_days", type = "integer", default = 30,
   min = 0, group = "summarizer", doc = "… once older than this many days." }
S{ env = "MEMO_SUMMARIZER_BATCH_SIZE", key = "summarizer_batch_size", type = "integer", default = 20, min = 1,
   group = "summarizer", doc = "Memories per summary." }
S{ env = "MEMO_SUMMARIZER_MAX_BATCHES", key = "summarizer_max_batches", type = "integer", default = 5,
   min = 1, group = "summarizer", doc = "Summaries per run (a cost cap)." }

-- ── maintenance ─────────────────────────────────────────────────────────────
S{ env = "MEMO_AUTO_DIGEST_ENABLED", key = "auto_digest_enabled", type = "boolean", default = false,
   group = "maintenance", aliases = { "MEMO_AUTO_DIGEST" },
   doc = "Writes keep memory maintained: tiers, consolidation, decay." }
S{ env = "MEMO_AUTO_DIGEST_INTERVAL", key = "auto_digest_interval", type = "integer", default = 3600, min = 0,
   group = "maintenance", doc = "At most one automatic maintenance per scope per this many seconds." }
S{ env = "MEMO_DIGEST_PROMOTE_TIER2_AT", key = "digest_promote_tier2_at", type = "integer", default = 3,
   min = 1, group = "maintenance", doc = "Times a memory is proven useful before it moves to tier 2." }
S{ env = "MEMO_DIGEST_PROMOTE_TIER3_AT", key = "digest_promote_tier3_at", type = "integer", default = 5,
   min = 1, group = "maintenance", doc = "Times a mistake recurs before its memory moves to tier 3 (core)." }
S{ env = "MEMO_DIGEST_GRACE_DAYS", key = "digest_grace_days", type = "integer", default = 7, min = 0,
   group = "maintenance", doc = "Days an ephemeral (tier 0) memory is kept once consolidated." }
S{ env = "MEMO_DIGEST_ESCALATE_ALPHA", key = "digest_escalate_alpha", type = "number", default = 0.4,
   min = 0, max = 1, group = "maintenance", doc = "How fast a recurring mistake's importance grows." }
S{ env = "MEMO_DIGEST_IDLE_SECONDS", key = "digest_idle_seconds", type = "integer", default = 1800, min = 0,
   group = "maintenance", doc = "A scope without writes for this long is due for a digest." }
S{ env = "MEMO_CONSOLIDATE_THRESHOLD", key = "consolidate_threshold", type = "number", default = 0.80, min = 0,
   max = 1, group = "maintenance", doc = "Similarity at which memories are grouped into an observation." }
S{ env = "MEMO_CONSOLIDATE_REINFORCE_THRESHOLD", key = "consolidate_reinforce_threshold", type = "number",
   default = 0.75, min = 0, max = 1, group = "maintenance",
   doc = "Similarity at which a group reinforces an existing observation." }
S{ env = "MEMO_CONSOLIDATE_LOG_ERRORS", key = "consolidate_log_errors", type = "boolean", default = false,
   group = "maintenance", doc = "Report the observations that failed to build in the consolidation result." }
S{ env = "MEMO_CORPUS_HEALTH_CHECK", key = "corpus_health_check", type = "boolean", default = false,
   group = "maintenance", doc = "Print memo doctor's corpus warnings (truncation) at startup." }

-- ── learning from use ───────────────────────────────────────────────────────
S{ env = "MEMO_FEEDBACK_ENABLED", key = "feedback_enabled", type = "boolean", default = false,
   group = "learning", doc = "Log searches and detect missed memories (what the learned reranker trains on)." }
S{ env = "MEMO_MISS_THRESHOLD", key = "miss_threshold", type = "number", default = 0.90, min = 0, max = 1,
   group = "learning", doc = "Similarity at which a new write reveals a memory a search missed." }
S{ env = "MEMO_GEN_MODEL", key = "gen_model", type = "string", group = "learning",
   doc = "GGUF instruct model for memo sense --generative." }
S{ env = "MEMO_GEN_NCTX", key = "gen_n_ctx", type = "integer", implied = 4096, min = 1, group = "learning",
   doc = "Context size of the generative model." }
S{ env = "MEMO_GEN_NGL", key = "gen_n_gpu", type = "integer", implied = 0, min = -1, group = "learning",
   doc = "GPU layers for the generative model: 0 CPU, N layers, -1 all." }

-- ── federation ──────────────────────────────────────────────────────────────
S{ env = "MEMO_ROLE", key = "role", type = "string", values = { "solo", "dev", "org" }, group = "federation",
   implied = function(cfg) return cfg.org_url and "dev" or "solo" end, strict = true,
   doc = "solo, dev (implied by MEMO_ORG_URL) or org (this instance is the org central)." }
S{ env = "MEMO_ORG_URL", key = "org_url", type = "string", group = "federation", mcp_env = true,
   doc = "dev: the org central's address (local network / VPN only)." }
S{ env = "MEMO_ORG_FINGERPRINT", key = "org_fingerprint", type = "string", group = "federation", mcp_env = true,
   doc = "dev: the central's key fingerprint, pinned (from the org admin)." }
S{ env = "MEMO_ORG_IDENTITY", key = "org_identity", type = "string", group = "federation", mcp_env = true,
   doc = "dev: user:<email> to pair as (default: git's user.email)." }
S{ env = "MEMO_ORG_NAME", key = "org_name", type = "string", group = "federation",
   doc = "org: the org's name (its scope is org:<name>)." }
S{ env = "MEMO_ORG_SHARE", key = "org_share", type = "string", default = "triples",
   values = { "triples", "signals" }, group = "federation", mcp_env = true, strict = true,
   doc = "dev: push feedback with the query text (triples) or without (signals)." }
S{ env = "MEMO_ORG_SYNC_TTL", key = "org_sync_ttl", type = "integer", default = 900, min = 0,
   group = "federation", doc = "dev: the org replica is synced again once this many seconds old." }
S{ env = "MEMO_ORG_PROPOSE", key = "org_propose", type = "boolean", default = true, group = "federation",
   mcp_env = true, doc = "dev: propose proven project knowledge to the org with each push (triples only)." }
S{ env = "MEMO_ORG_PROPOSE_SCOPES", key = "org_propose_scopes", type = "list", group = "federation",
   mcp_env = true, doc = "dev: only these repo: scopes may propose, comma-separated (default: every repo: scope)." }
S{ env = "MEMO_ORG_PROPOSALS", key = "org_proposals", type = "boolean", default = true, group = "federation",
   doc = "org: take the devs' knowledge proposals into the review queue." }
S{ env = "MEMO_ORG_KNOWLEDGE_DECAY", key = "org_knowledge_decay", type = "number", default = 0.01, min = 0,
   max = 1, group = "federation", doc = "org: daily decay of approved knowledge (being used restarts its clock)." }
S{ env = "MEMO_ORG_PREFIX", key = "org_prefix", type = "string", default = "/federation", group = "federation",
   doc = "dev: the path of the central's federation API (memo serve --prefix)." }
S{ env = "MEMO_FEDERATION_DIR", key = "federation_dir", type = "string", group = "federation", mcp_env = true,
   doc = "The per-user luamemo directory: this device's keys, the org registry, the vault key and the list of "
      .. "trusted settings files (default ~/.config/luamemo)." }

-- ── secrets ─────────────────────────────────────────────────────────────────
S{ env = "MEMO_MASTER_KEY_PATH", key = "master_key_path", type = "string", group = "secrets",
   doc = "File holding the vault's key (64 hex characters). Default: ~/.config/luamemo/vault.key, which the "
      .. "first memo secret-store creates." }
S{ env = "MEMO_MASTER_KEY_ENV", key = "master_key_env", type = "string", group = "secrets",
   doc = "Name of an environment variable holding the master key." }
S{ env = "MEMO_MASTER_KEY", key = "master_key", type = "string", group = "secrets", secret = true,
   doc = "The master key itself — prefer MEMO_MASTER_KEY_PATH (never shown; not written by memo config)." }

M.LIST = L

local BY = {}
for _, e in ipairs(L) do
    BY[e.env] = e
    if e.key then BY[e.key] = e end
    for _, a in ipairs(e.aliases or {}) do BY[a] = e end
end

-- MEMO_ variables luamemo's tools read that are not settings (paths, debugging, hooks):
-- name → what it does (listed in SETTINGS.md), or true for luamemo's own plumbing.
M.OTHER_VARS = {
    MEMO_PROJECT = "The project directory whose .luamemorc memo reads and writes (default: the nearest directory "
        .. "from here up that holds a .luamemorc, else the current one; memo calibrate --root and memo mcp "
        .. "--project win over it).",
    MEMO_LUA = "The LuaJIT interpreter memo runs: a name or a path (default: luajit).",
    MEMO_LIB_SQLITE3 = "Load this libsqlite3 instead of the system's (a path).",
    MEMO_LIB_SODIUM = "Load this libsodium instead of the system's (a path).",
    MEMO_DEBUG = "1: the MCP server logs every JSON-RPC message to stderr; memo brief adds the database error.",
    MEMO_BRIEF_TIMEOUT = "Seconds memo brief may take before it gives up (default 5) — it runs from session-start hooks.",
    MEMO_HOOK_MAX_MESSAGES = "Messages a capture hook saves from the transcript (default 20).",
    MEMO_HOOK_MAX_CHARS = "Characters a capture hook keeps per message (default 500).",
    MEMO_HOOK_COOLDOWN_SECS = "Claude Code's post-message hook saves at most once per this many seconds (default 300).",
    MEMO_INDEX_NO_CTAGS = "1: memo index never uses universal-ctags.",
    MEMO_RERANK_WEIGHTS = "The learned reranker's global weights file, used for a scope without promoted weights "
        .. "(default luamemo/rerank_weights.json, relative to the working directory).",
    MEMO_PROJECTION_W = "The projected embedder's weights file (default luamemo/projection_W.json, relative to the "
        .. "working directory).",
    MEMO_TEST_TMP = true, MEMO_API_CMD = true,
}

-- Names older luamemo versions read, and what replaced them.
local PAIRED = "org devices authenticate with their paired key now (memo calibrate pairs them)"
local NO_SERVER = "the HTTP server mode is gone; memo and the MCP server work on the database directly"
M.RETIRED = {
    MEMO_DB_URL = "luamemo keeps memories in a SQLite file now, named by MEMO_DB (memo calibrate sets it)",
    MEMO_SECRETS_FILE = "secrets live in the database now (memo secret-store)",
    MEMO_URL = NO_SERVER, MEMO_TOKEN = NO_SERVER,
    MEMO_ORG_TOKEN_FILE = PAIRED, MEMO_ORG_TOKEN = PAIRED, MEMO_ORG_TOKENS = PAIRED,
}

--- The entry of a MEMO_ name, a config key, or a name without MEMO_ (any case) | nil.
function M.get(name)
    if type(name) ~= "string" then return nil end
    local up = name:upper()
    return BY[name] or BY[up] or BY[name:lower()] or BY["MEMO_" .. up]
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

--- A new config table holding every default.
function M.defaults()
    local cfg = {}
    for _, e in ipairs(L) do
        if e.key and e.default ~= nil then cfg[e.key] = copy(e.default) end
    end
    return cfg
end

--- The value in force when the setting is unset (its default, or what the module applies).
function M.implied(e, cfg)
    if e.default ~= nil then return copy(e.default) end
    if type(e.implied) == "function" then return e.implied(cfg or {}) end
    return e.implied
end

local TRUE = { ["1"] = true, ["true"] = true, yes = true, on = true }
local FALSE = { ["0"] = true, ["false"] = true, no = true, off = true }

local function json() return require("luamemo.json") end

-- Checks of the JSON-valued settings → nil | err.
local function check_json(e, t)
    if e.headers then
        for k, v in pairs(t) do
            if type(k) ~= "string" or not k:match("^[%w!#$%%&'*+%-.^_`|~]+$") then
                return ("%s: %q is not a header name"):format(e.env, tostring(k))
            end
            if type(v) ~= "string" or v:find("[\r\n]") then
                return ("%s: the value of %s must be one line of text"):format(e.env, k)
            end
        end
    elseif e.key == "hybrid_weights" then
        local total = 0
        for k, v in pairs(t) do
            if (k ~= "vector" and k ~= "fts") or type(v) ~= "number" or v < 0 then
                return e.env .. ' must be {"vector": number, "fts": number}, neither below 0'
            end
            total = total + v
        end
        if total <= 0 then return e.env .. ": the weights can't both be 0" end
    end
end

--- Text (.luamemorc, the environment, a command line) → value | nil, err.
function M.parse(e, text)
    if text == nil then return nil, e.env .. ": no value" end
    local s = tostring(text):match("^%s*(.-)%s*$")
    local v
    if e.type == "boolean" then
        local l = s:lower()
        if TRUE[l] then v = true elseif FALSE[l] then v = false
        else return nil, ("%s must be true or false (or 1 / 0), not %q"):format(e.env, s) end
    elseif e.type == "number" or e.type == "integer" then
        v = tonumber(s)
        if not v or v ~= v or v == math.huge or v == -math.huge then
            return nil, ("%s must be a number, not %q"):format(e.env, s)
        end
        if e.type == "integer" and v ~= math.floor(v) then
            return nil, ("%s must be a whole number, not %q"):format(e.env, s)
        end
        if (e.min and v < e.min) or (e.max and v > e.max) then
            local range = (e.min and e.max) and ("between %s and %s"):format(e.min, e.max)
                or e.min and ("at least %s"):format(e.min) or ("at most %s"):format(e.max)
            return nil, ("%s must be %s, not %s"):format(e.env, range, s)
        end
    elseif e.type == "list" then
        v = {}
        for item in s:gmatch("[^,%s]+") do v[#v + 1] = item end
        if #v == 0 then return nil, e.env .. ": empty list" end
    elseif e.type == "json" then
        local t = json().decode(s)
        if type(t) ~= "table" or t[1] ~= nil then
            return nil, ("%s must be a JSON object, not %q"):format(e.env, s)
        end
        local err = check_json(e, t)
        if err then return nil, err end
        v = t
    else
        if s == "" then return nil, e.env .. ": empty value" end
        if s:find("[\r\n]") then return nil, e.env .. ": one line only" end
        v = s
    end
    if e.values and type(v) == "string" then
        local ok = false
        for _, a in ipairs(e.values) do if a == v then ok = true end end
        if not ok then
            return nil, ("%s must be one of %s, not %q"):format(e.env, table.concat(e.values, " | "), v)
        end
    end
    return v
end

-- A flat JSON object with its keys in order (the encoder's order is random).
local function sorted_json(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = json().encode(k) .. ":" .. json().encode(t[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function num(v)
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
    return ("%.14g"):format(v)
end

--- Value → its .luamemorc text.
function M.format(e, v)
    if v == nil then return nil end
    if e.type == "boolean" then return v and "true" or "false" end
    if e.type == "list" and type(v) == "table" then return table.concat(v, ",") end
    if e.type == "json" and type(v) == "table" then return sorted_json(v) end
    if type(v) == "number" then return num(v) end
    return tostring(v)
end

local SENSITIVE = { "auth", "key", "token", "secret", "cookie", "password" }

--- Header names in a headers value carrying a credential in plain text: an
--- Authorization / key / token / secret / cookie / password header without {secret:…}.
function M.plain_credentials(e, v)
    local bad = {}
    if not (e and e.headers) or type(v) ~= "table" then return bad end
    for name, value in pairs(v) do
        local n = tostring(name):lower()
        local sensitive = false
        for _, w in ipairs(SENSITIVE) do if n:find(w, 1, true) then sensitive = true end end
        if sensitive and not tostring(value):find("{secret:", 1, true) then bad[#bad + 1] = tostring(name) end
    end
    table.sort(bad)
    return bad
end

--- The text shown for a value: the master key never, a plain credential in a header masked.
function M.show(e, v)
    if v == nil then return nil end
    if e.secret then return "(set)" end
    if e.headers and type(v) == "table" then
        local masked = {}
        for k, x in pairs(v) do masked[k] = x end
        for _, name in ipairs(M.plain_credentials(e, v)) do masked[name] = "****" end
        return sorted_json(masked)
    end
    local text = M.format(e, v)
    -- A URL may carry a credential (user:password@, ?key=…): shown masked — this view
    -- reaches agents (memory_status details).
    if type(text) == "string" and text:find("://", 1, true) then
        return require("luamemo.util").redact_url(text)
    end
    return text
end

--- The settings set in the environment → { key = value }, { problem, … }, { fatal, … }.
--- get(name) reads one variable; an empty value counts as unset. The first of a
--- setting's names that is set is used (the current name before its older ones). A
--- value that doesn't parse is a problem (the setting keeps its default) — or, for a
--- strict setting, fatal. Settings without a config key (MEMO_SCOPE, MEMO_CA_FILE) are
--- read where they are used.
function M.from_env(get)
    local cfg, problems, fatal = {}, {}, {}
    for _, e in ipairs(L) do
        if e.key then
            local names = { e.env }
            for _, a in ipairs(e.aliases or {}) do names[#names + 1] = a end
            for _, name in ipairs(names) do
                local raw = get(name)
                if raw ~= nil and raw ~= "" then
                    local v, err = M.parse(e, raw)
                    if v ~= nil then cfg[e.key] = v
                    elseif e.strict then fatal[#fatal + 1] = err
                    else problems[#problems + 1] = err .. " — ignored" end
                    break
                end
            end
        end
    end
    return cfg, problems, fatal
end

-- Edit distance, for "did you mean".
local function distance(a, b)
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local c = (a:byte(i) == b:byte(j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + c)
        end
        prev = cur
    end
    return prev[#b]
end

--- The MEMO_ names luamemo doesn't read → { { name, suggestion?, retired? }, … }:
--- suggestion = the closest setting when close enough, retired = what replaced an old
--- name. MEMO__* are luamemo's own internal variables.
function M.unknown(names)
    local out = {}
    for _, name in ipairs(names) do
        if name:match("^MEMO_") and not name:match("^MEMO__") and not BY[name] and not M.OTHER_VARS[name] then
            local best, bd = nil, math.huge
            for _, e in ipairs(L) do
                local d = distance(name, e.env)
                if d < bd then best, bd = e.env, d end
            end
            out[#out + 1] = { name = name, retired = M.RETIRED[name],
                              suggestion = (bd <= math.max(2, math.floor(#name / 5))) and best or nil }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- One line about an unknown name (from M.unknown).
function M.unknown_message(u)
    if u.retired then return ("%s is no longer read: %s"):format(u.name, u.retired) end
    return ("%s is not a luamemo setting%s"):format(u.name,
        u.suggestion and (" — did you mean " .. u.suggestion .. "?") or " (memo config list shows them all)")
end

--- The names of the MEMO_ variables set in this process.
function M.env_names()
    local ok, names = pcall(function()
        local ffi = require("luamemo.native.loader").ffi
        pcall(ffi.cdef, "extern char **environ;")
        local got, envp = pcall(function() return ffi.C.environ end)
        if not got or envp == nil then   -- macOS: environ isn't reachable through dlsym everywhere
            pcall(ffi.cdef, "char ***_NSGetEnviron(void);")
            envp = ffi.C._NSGetEnviron()[0]
        end
        local out, i = {}, 0
        while envp[i] ~= nil do
            local name = ffi.string(envp[i]):match("^(MEMO_[%w_]*)=")
            if name then out[#out + 1] = name end
            i = i + 1
        end
        return out
    end)
    return ok and names or {}
end

-- $NAME / ${NAME} and a leading ~/ in an unquoted or "double-quoted" value (cli/memo's
-- _rc_value does the same; nothing else is expanded and nothing runs).
local function expand(v)
    v = v:gsub("^~/", function() return (os.getenv("HOME") or "~") .. "/" end)
    return (v:gsub("%${?([%a_][%w_]*)}?", function(n) return os.getenv(n) or "" end))
end

--- A .luamemorc's KEY=value lines → { MEMO_NAME = text }. Values are read as `memo`
--- (the shell) reads them: 'single-quoted' literally ('\'' for a quote), "double-quoted"
--- or bare with $VAR expanded; a bare value ends at " #".
function M.read_file(path)
    local out = {}
    local f = path and io.open(path, "r")
    if not f then return out end
    for line in f:lines() do
        local k, v = line:match("^%s*export%s+(MEMO_[%w_]+)=(.*)$")
        if not k then k, v = line:match("^%s*(MEMO_[%w_]+)=(.*)$") end
        if k then
            if v:sub(1, 1) == "'" then
                v = (v:match("^'(.*)'%s*$") or v:sub(2)):gsub("'\\''", "'")
            elseif v:sub(1, 1) == '"' then
                v = expand(v:match('^"(.*)"%s*$') or v:sub(2)):gsub('\\(["\\$`])', "%1")
            else
                v = expand((v:gsub("%s+#.*$", ""):gsub("%s+$", "")))
            end
            out[k] = v
        end
    end
    f:close()
    return out
end

-- The working directory (getcwd — an MCP client may start the server without PWD).
local function cwd()
    local ok, dir = pcall(function()
        local ffi = require("luamemo.native.loader").ffi
        pcall(ffi.cdef, "char *getcwd(char *buf, size_t size);")
        local buf = ffi.new("char[?]", 4096)
        local p = ffi.C.getcwd(buf, 4096)
        return p ~= nil and ffi.string(p) or nil
    end)
    return (ok and dir) or os.getenv("PWD") or "."
end

-- ---------------------------------------------------------------------------
-- Trust. A project's .luamemorc is used only when memo wrote it or its user trusted it,
-- as it is now (both record its checksum; a changed file needs trusting again — memo
-- config trust). One committed to git came with the repository, and an uncommitted one
-- may have come with a download (a zip, a tarball, a copied folder): content nobody on
-- this machine wrote, which could send the memories — and the vault's secrets, through
-- {secret:NAME} headers — to a server it names (owner, 2026-10-16). cli/memo applies the
-- same rule (_rc_usable). ~/.luamemorc is the user's own.
--
-- And whatever the trust, a project's file never names code for luamemo to run or load
-- (USER_ONLY: the interpreter, the native libraries, the GGUF shim) — only the
-- environment and ~/.luamemorc do (cli/memo: _RC_USER_ONLY).
-- ---------------------------------------------------------------------------

M.USER_ONLY = { MEMO_LUA = true, MEMO_LIB_SQLITE3 = true, MEMO_LIB_SODIUM = true,
                MEMO_GGUF_SHIM = true, MEMO_GEMMA_SHIM = true }

--- The per-user list of trusted files: lines "<sha256 hex> <absolute path>".
function M.trust_file()
    local dir = os.getenv("MEMO_FEDERATION_DIR")
    if not dir or dir == "" then
        local xdg = os.getenv("XDG_CONFIG_HOME")
        dir = ((xdg and xdg ~= "") and xdg or ((os.getenv("HOME") or "") .. "/.config")) .. "/luamemo"
    end
    return dir .. "/trusted_rc"
end

-- The file's absolute, symlink-free path (as `pwd -P` gives it) and its checksum.
local function identity(path)
    local util = require("luamemo.util")
    local dir, base = path:match("^(.*)/([^/]+)$")
    if not dir then dir, base = ".", path end
    if dir == "" then dir = "/" end
    local real = util.real_dir(dir)
    local f = io.open(path, "rb")
    if not real or not f then if f then f:close() end; return nil end
    local text = f:read("*a"); f:close()
    local sodium = require("luamemo.native.sodium")
    return real .. "/" .. base, util.to_hex(sodium.sha256(text))
end

local function committed(path)
    local q = require("luamemo.util").shell_quote
    local dir, base = path:match("^(.*)/([^/]+)$")
    if not dir then dir, base = ".", path end
    local r = os.execute(("git -C %s ls-files --error-unmatch -- %s >/dev/null 2>&1"):format(q(dir), q(base)))
    return r == 0 or r == true
end

--- May luamemo use the project settings file at `path`? → true | false, why | nil (no file).
function M.trusted(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    local abs, sum = identity(path)
    local tf = io.open(M.trust_file(), "r")
    if tf and abs then
        for line in tf:lines() do
            if line == sum .. " " .. abs then tf:close(); return true end
        end
    end
    if tf then tf:close() end
    if committed(path) then
        return false, "it is committed to the repository (not written on this machine) and you haven't trusted it"
    end
    return false, "memo didn't write it as it is now (it may have come with the project, or been edited) "
        .. "and you haven't trusted it"
end

--- Trust the settings file at `path` as it is now (replacing its earlier entry). → true | nil, err
function M.trust(path)
    local abs, sum = identity(path)
    if not abs then return nil, "cannot read " .. path end
    local tf = M.trust_file()
    local keep = {}
    local r = io.open(tf, "r")
    if r then
        for line in r:lines() do
            if line ~= "" and line:match("^%S+ (.*)$") ~= abs then keep[#keep + 1] = line end
        end
        r:close()
    end
    keep[#keep + 1] = sum .. " " .. abs
    -- 0600 in the per-user config dir (forced 0700 — it holds the keyring and vault key);
    -- it records which project settings files memo wrote or the owner reviewed.
    local util = require("luamemo.util")
    util.private_dir(tf:match("^(.*)/[^/]+$"), true)
    return util.write_private(tf, table.concat(keep, "\n") .. "\n")
end

--- Is the file committed to git? (memo config trust says so.)
M.committed = committed

--- The project directory: the nearest directory from `start` (default: the working
--- directory) up that holds a .luamemorc — a subfolder of a project is that project;
--- the home directory's own file is the user file, not a project — else `start`
--- itself. cli/memo's _find_project walks the same way.
function M.project_dir(start)
    local home = (os.getenv("HOME") or ""):gsub("/+$", "")
    local d = (start and start ~= "") and start or cwd()
    d = (d:gsub("/+$", "")); if d == "" then d = "/" end
    local first = d
    while true do
        if d ~= home then
            local f = io.open((d == "/" and "" or d) .. "/.luamemorc", "r")
            if f then f:close(); return d end
        end
        if d == "/" or d == home or d == "" then return first end
        d = d:match("^(.*)/[^/]*$") or "/"
        if d == "" then d = "/" end
    end
end

--- The settings files, read: { project = …, user = … (read_file maps), paths = {
--- project, user }, dir = the project directory, untrusted = why (the project file was
--- left unread) }. The project is project_dir, else the one memo names, else
--- MEMO_PROJECT, else the nearest one up from the working directory (M.project_dir).
--- A project file committed to git that nobody trusted (M.trusted) is not read.
--- (~/.memorc, the older name of the user file, is no longer read — memo calibrate
--- moves it into ~/.luamemorc.)
function M.files(project_dir)
    local home, dir = os.getenv("HOME") or "", nil
    for _, d in ipairs({ project_dir or "", os.getenv("MEMO__PROJECT_DIR") or "", os.getenv("MEMO_PROJECT") or "" }) do
        if d ~= "" then dir = d; break end
    end
    dir = dir or M.project_dir()
    local paths = { project = dir .. "/.luamemorc", user = home .. "/.luamemorc" }
    local out = { user = M.read_file(paths.user), paths = paths, project = {}, dir = dir }
    if paths.project ~= paths.user then
        local ok, why = M.trusted(paths.project)
        if ok then out.project = M.read_file(paths.project)
        elseif ok == false then out.untrusted = why end
    end
    for k in pairs(M.USER_ONLY) do
        if out.project[k] ~= nil then
            out.project[k] = nil
            out.user_only = out.user_only or {}
            out.user_only[#out.user_only + 1] = k
        end
    end
    if out.user_only then table.sort(out.user_only) end
    return out
end

--- The line about the USER_ONLY settings a project file names (files().user_only).
function M.user_only_message(path, keys)
    return ("ignoring %s in %s — a project's settings never name code to run; set it in ~/.luamemorc "
        .. "or the environment"):format(table.concat(keys, ", "), path)
end

--- The line about a project file left unread (files().untrusted).
function M.untrusted_message(path, why)
    return ("ignoring %s — %s. Review it; if it's fine: memo config trust"):format(path, why)
end

--- For a process `memo` didn't start — the MCP server, which an MCP client launches —
--- the settings files into the environment, as `memo` sources them: the project's
--- .luamemorc over ~/.luamemorc. A variable already set wins: the client's config
--- passes its own (calibrate writes the database's full path there).
--- Returns { MEMO_X = "project" | "user" } for the variables it set.
function M.load_files(project_dir)
    local files = M.files(project_dir)
    if files.untrusted then
        io.stderr:write("[luamemo] ", M.untrusted_message(files.paths.project, files.untrusted), "\n")
    end
    if files.user_only then
        io.stderr:write("[luamemo] ", M.user_only_message(files.paths.project, files.user_only), "\n")
    end
    local ffi = require("luamemo.native.loader").ffi
    pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
    local set = {}
    for _, which in ipairs({ "project", "user" }) do
        for k, v in pairs(files[which]) do
            local have = os.getenv(k)
            if (have == nil or have == "") and v ~= "" then
                ffi.C.setenv(k, v, 1)
                set[k] = which
            end
        end
    end
    return set
end

--- Every setting's effective value and where it came from: "project" / "user" (that
--- file holds the value in force), "environment", or "default". cfg is the config in
--- force (settings without a config key are read with getenv); files from M.files.
function M.effective(cfg, files, getenv)
    files, getenv = files or {}, getenv or os.getenv
    local out = {}
    for _, e in ipairs(L) do
        local v
        if e.key then v = cfg[e.key] else
            local raw = getenv(e.env)
            if raw ~= nil and raw ~= "" then v = M.parse(e, raw) end
        end
        local shown = M.format(e, v)
        local function holds(file)
            if not file then return false end
            local t = file[e.env]
            for _, a in ipairs(e.aliases or {}) do t = t or file[a] end
            if t == nil or t == "" then return false end
            local pv = M.parse(e, t)
            return pv ~= nil and M.format(e, pv) == shown
        end
        local source
        if v == nil then
            source, v = "default", M.implied(e, cfg)
        elseif holds(files.project) then source = "project"
        elseif holds(files.user) then source = "user"
        elseif shown == M.format(e, M.implied(e, cfg)) then source = "default"
        else source = "environment" end
        out[#out + 1] = { entry = e, value = v, source = source }
    end
    return out
end

--- The settings in force, for display: { { name, value, source, group }, … } — value is
--- the shown text (a credential masked; absent when unset). files: M.files() by default.
function M.view(cfg, files, getenv)
    local out = {}
    for _, r in ipairs(M.effective(cfg, files or M.files(), getenv)) do
        out[#out + 1] = { name = r.entry.env, value = M.show(r.entry, r.value), source = r.source,
                          group = r.entry.group }
    end
    return out
end

return M
