-- Minimal Lapis app demonstrating lapis-memory integration.
-- Run with: lapis server

local lapis  = require("lapis")
local memory = require("lapis_memory")

local app = lapis.Application()

-- Simple bearer-token auth for the demo.
local API_TOKEN = os.getenv("MEMO_TOKEN") or "dev-token"

memory.setup({
    embedder_url     = os.getenv("EMBEDDER_URL") or "http://localhost:8000/embed",
    embedder_adapter = "generic",
    embed_dim        = 384,
    default_scope    = "repo:demo",
    auth_fn = function(self)
        local h = self.req.headers["Authorization"] or ""
        return h == "Bearer " .. API_TOKEN
    end,
})

memory.routes.register(app, { prefix = "/api/memory" })

app:get("/", function() return "lapis-memory demo OK" end)

return app
