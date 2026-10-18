-- eval/tests/test_secret_execute.lua
-- secret_execute's answer and its uploads (luamemo.secrets.execute_with_secret):
--   the response never carries the secret back — as sent, URL-encoded or JSON-escaped
--   (a server that echoes the request would otherwise hand it to the agent);
--   max_bytes bounds it (truncated says so), and the MCP tool defaults to 64 KB;
--   uploads from the MCP tool (restrict_uploads): a regular file inside the project only
--   — not outside it, not through a symlinked directory, not hidden, not a credential
--   file, not when the server runs in / or the home directory; the CLI takes its path
--   as given (a regular file, not a symlink); a field name / content type can't break
--   the part's headers.
-- The HTTP client is stubbed: nothing leaves this machine.
-- Run: luajit eval/tests/run.lua --only secret_execute

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("secret_execute")
local check, section, finish = T.check, T.section, T.finish
local json = require("luamemo.json")

local lm = require("luamemo")
lm.setup({ embedder_local = "hash", embed_dim = 384, skip_embed_probe = true, master_key = ("cd"):rep(32) })
local secrets = require("luamemo.secrets")
local http = require("luamemo.http")
local SECRET = "sk-live/Ab+Cd\"9"   -- a slash, a plus and a quote: every encoding differs
assert(secrets.store("api", SECRET, "test key"))

-- The stub: the response is whatever `reply` builds from the request; `sent` keeps it.
local sent, reply
http.request = function(url, opts)
    sent = { url = url, opts = opts }
    local body = reply(url, opts)
    local max = tonumber(opts.max_bytes)
    if max and #body > max then return 200, body:sub(1, max), nil, true end
    return 200, body, nil, false
end
local URL = "https://93.184.215.14/v1?key={secret}"   -- a public address: no DNS, no network

section("the response never carries the secret", function()
io.write("\n--- masking ---\n")
reply = function(url, opts)
    -- an echo service: the request back, in the shapes such services answer
    return json.encode({ url = url, auth = opts.headers.Authorization, body = opts.body }) .. " raw:" .. SECRET
end
local body, err = secrets.execute_with_secret("api", { url = URL, method = "POST",
    headers = { Authorization = "Bearer {secret}" }, body = "token={secret}" })
check("the request carried the value (substituted server-side)", sent and sent.opts.headers.Authorization
    == "Bearer " .. SECRET and sent.opts.body == "token=" .. SECRET, err)
local enc = SECRET:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end)
check("… the answer holds it in no form: raw, JSON-escaped (either encoder), URL-encoded", body ~= nil
    and not body:find(SECRET, 1, true) and not body:find((SECRET:gsub("/", "\\/"):gsub('"', '\\"')), 1, true)
    and not body:find((SECRET:gsub('"', '\\"')), 1, true)
    and not body:find(enc, 1, true) and not body:lower():find(enc:lower(), 1, true)
    and select(2, body:gsub("%*%*%*", "")) >= 3, body)
check("mask leaves a short value alone (it isn't a secret, masking would garble)",
    secrets.mask("abc def", "abc") == "abc def")
end)

section("the answer is bounded", function()
io.write("\n--- size ---\n")
reply = function() return ("x"):rep(200000) end
local body, _, info = secrets.execute_with_secret("api", { url = URL, max_bytes = 4096 })
check("max_bytes cuts the body, and says so", #body == 4096 and info and info.truncated == true, #body)
local small = secrets.execute_with_secret("api", { url = URL })
check("without max_bytes (the CLI) the whole body", #small == 200000)
-- the MCP tool's default
local s = H.mcp_session(("MEMO_DB=%q MEMO_MASTER_KEY=%s MEMO_EMBEDDER=hash"):format(os.getenv("MEMO_DB"),
    ("cd"):rep(32)), { cmd = ("%q -e %q"):format(H.lua_bin(), ([[
        package.path = "./?.lua;./?/init.lua;" .. package.path
        local http = require("luamemo.http")
        http.request = function(_, opts)
            local b = ("y"):rep(300000)
            local max = tonumber(opts.max_bytes)
            if max and #b > max then return 200, b:sub(1, max), nil, true end
            return 200, b, nil, false
        end
        arg = { [0] = "mcp/server.lua" }
        dofile("mcp/server.lua")]])) })
local r = s.call("secret_execute", { name = "api", url = URL })
s.close()
check("the MCP tool: 64 KB by default, truncated = true", type(r.response) == "string"
    and #r.response == 65536 and r.truncated == true, json.encode({ #(r.response or ""), r.truncated, r.error }))
end)

section("uploads from the MCP tool: the project's files only", function()
io.write("\n--- uploads ---\n")
reply = function(_, opts) return "got " .. #(opts.body or "") .. " bytes" end
local base = os.tmpname(); os.remove(base)
local proj, outside = base .. "-proj", base .. "-outside"
os.execute(("mkdir -p %q %q %q %q"):format(proj .. "/docs", proj .. "/.git", proj .. "/keys", outside))
local function put(p, text) local f = assert(io.open(p, "w")); f:write(text); f:close() end
put(proj .. "/.luamemorc", "MEMO_SCOPE='repo:up'\n")
put(proj .. "/docs/report.txt", "the report")
put(proj .. "/.env", "TOKEN=1")
put(proj .. "/.git/config", "[remote]")
put(proj .. "/keys/server.pem", "-----BEGIN")
put(outside .. "/notes.txt", "not the project's")
os.execute(("ln -s %q %q"):format(outside, proj .. "/docs/elsewhere"))
os.execute(("ln -s %q %q"):format(proj .. "/docs/report.txt", proj .. "/docs/link.txt"))
local ffi = require("ffi"); pcall(ffi.cdef, "int setenv(const char*, const char*, int);")
ffi.C.setenv("MEMO__PROJECT_DIR", proj, 1)
local function upload(path, restrict, field, ct)
    return secrets.execute_with_secret("api", { url = URL, restrict_uploads = restrict ~= false,
        multipart = { [field or "file"] = { file = path, content_type = ct } } })
end
local ok1 = upload("docs/report.txt")
local ok2 = upload(proj .. "/docs/report.txt")
check("a file inside the project: relative to it, or absolute within it", ok1 and ok2 and ok1:find("got") ~= nil)
local cases = {
    { "../" .. outside:match("[^/]+$") .. "/notes.txt", "outside" },
    { outside .. "/notes.txt", "outside" },
    { "docs/elsewhere/notes.txt", "outside" },
    { ".env", "hidden" }, { ".git/config", "hidden" }, { ".luamemorc", "hidden" },
    { "keys/server.pem", "credential" },
    { "docs/link.txt", "symlink" },
    { "/etc/passwd", "outside" },
}
for _, c in ipairs(cases) do
    local b, e = upload(c[1])
    check(("refused: %s (%s)"):format(c[1], c[2]), b == nil and e ~= nil, tostring(e))
end
ffi.C.setenv("MEMO__PROJECT_DIR", os.getenv("HOME"), 1)
local b3, e3 = upload("anything.txt")
check("no uploads when the server runs in the home directory (no project)", b3 == nil
    and tostring(e3):find("project directory", 1, true) ~= nil, e3)
ffi.C.setenv("MEMO__PROJECT_DIR", proj, 1)
local b4 = upload(outside .. "/notes.txt", false)
check("the CLI (no restriction) takes the path as given", b4 ~= nil)
local b5 = upload(outside .. "/../" .. outside:match("[^/]+$") .. "/notes.txt", false)
check("… still a regular file", b5 ~= nil)
local b6, e6 = upload("docs/report.txt", true, 'f"\r\nX-Evil: 1')
local b7, e7 = upload("docs/report.txt", true, "file", "text/plain\r\nX-Evil: 1")
check("a field name / content type with a quote or line break is refused", b6 == nil and b7 == nil, tostring(e6) .. tostring(e7))
-- Each file is read whole: an agent naming a huge one would exhaust the server's memory.
local cap = secrets.MAX_UPLOAD_BYTES
secrets.MAX_UPLOAD_BYTES = 4
local b8, e8 = upload("docs/report.txt")
local b9 = upload(proj .. "/docs/report.txt", false)
secrets.MAX_UPLOAD_BYTES = cap
check("the MCP tool's uploads are capped (MAX_UPLOAD_BYTES, 50 MB); the CLI's aren't", b8 == nil
    and tostring(e8):find("MB together", 1, true) ~= nil and b9 ~= nil and cap == 50 * 1024 * 1024, tostring(e8))
os.execute(("rm -rf %q %q"):format(proj, outside))
end)

finish()
