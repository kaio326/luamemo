-- dev/app.lua
-- Minimal Lapis host app for developing luamemo.
--
-- The repo root is mounted at /app inside the container; this file is loaded
-- as "app" from /app/dev/ (first entry in lua_package_path).
-- The library itself lives at /app/luamemo/ — no luarocks install needed.
-- With lua_code_cache off, edits to any luamemo/*.lua file take effect
-- on the next HTTP request without restarting the container.

local lapis  = require("lapis")
local memory = require("luamemo")

local app = lapis.Application()

local TOKEN = os.getenv("MEMO_TOKEN") or "dev-token"

memory.setup({
    -- Pure-Lua hash embedder + bruteforce backend: zero external dependencies,
    -- works offline, no pgvector needed. Good enough for dev/AI-assisted work.
    embedder_local = "hash",
    embed_dim      = 384,
    backend        = "bruteforce",
    default_scope  = "luamemo-dev",

    -- Encrypted secrets file, stored in the named Docker volume at /data.
    -- Survives container restarts; never written to the repo source tree.
    secrets_file   = os.getenv("MEMO_SECRETS_FILE") or "/data/secrets.json",
    master_key_env = "MEMO_MASTER_KEY",

    -- Simple bearer-token guard.  Return truthy to allow, falsy to deny.
    auth_fn = function(self)
        local h = self.req.headers["Authorization"] or ""
        return h == "Bearer " .. TOKEN
    end,
})

memory.routes.register(app, { prefix = "/api/memory" })

app:get("/", function()
    return { json = { ok = true, service = "luamemo-dev", version = "dev" } }
end)

return app
