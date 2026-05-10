-- Minimal Lapis app demonstrating luamemo integration.
-- Requires: OpenResty / Lapis, PostgreSQL, luamemo installed via luarocks.
-- Run with: lapis server

local lapis  = require("lapis")
local memory = require("luamemo")

local app = lapis.Application()

-- Simple bearer-token auth for the demo.
local API_TOKEN = os.getenv("MEMO_TOKEN") or "dev-token"

memory.setup({
    -- Embedder: "hash" uses the built-in pure-Lua embedder (zero deps).
    -- Switch to "ollama", "openai", etc. when you need semantic similarity.
    embedder_local = "hash",
    embed_dim      = 384,
    default_scope  = "repo:demo",
    auth_fn = function(self)
        local h = self.req.headers["Authorization"] or ""
        return h == "Bearer " .. API_TOKEN
    end,
    -- PostgreSQL is managed by Lapis/OpenResty (nginx.conf pool).
    -- For plain Lua outside OpenResty, pass pg_host/pg_port/pg_database/
    -- pg_user/pg_password here instead, or set PGHOST/PGDATABASE/etc. env vars.
})

memory.routes.register(app, { prefix = "/api/memory" })

app:get("/", function() return "luamemo demo OK" end)

return app
