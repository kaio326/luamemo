-- luamemo.cli.serve
-- `memo serve` — run this instance as the org central's federation endpoint.
--
--   memo serve [--host 127.0.0.1] [--port 8765] [--prefix /federation]
--
-- Requires MEMO_ROLE=org + MEMO_ORG_NAME. Local network only: --host must be
-- loopback, a LAN / VPN address (e.g. this machine's Tailscale IP), or 0.0.0.0
-- / :: (all interfaces — public peers are then dropped per connection). Devs
-- authenticate with paired device keys over an encrypted channel; no TLS proxy
-- or tokens are involved.

local M = {}

local die = require("luamemo.cli._common").die_for("serve", 2)

function M.run(argv)
    local opts = { host = "127.0.0.1", port = 8765 }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "--host" then opts.host = argv[i + 1]; i = i + 2
        elseif a == "--port" then opts.port = tonumber(argv[i + 1]); i = i + 2
        elseif a == "--prefix" then opts.prefix = argv[i + 1]; i = i + 2
        elseif a == "--max-requests" then opts.max_requests = tonumber(argv[i + 1]); i = i + 2
        elseif a == "-h" or a == "--help" then
            io.write("usage: memo serve [--host 127.0.0.1] [--port 8765] [--prefix /federation]\n"
                .. "  Serves the org central's federation API on the local network (requires\n"
                .. "  MEMO_ROLE=org and MEMO_ORG_NAME). --host: loopback, a LAN / VPN (e.g.\n"
                .. "  Tailscale) address, or 0.0.0.0 — public peers are always refused.\n")
            return
        else die("unknown argument: " .. tostring(a)) end
    end
    if not opts.port or opts.port < 0 or opts.port > 65535 then die("invalid --port") end

    local luamemo = require("luamemo.cli._common").setup_or_die(die, { prefix = "setup failed: ", code = 1 })

    if require("luamemo.federation.policy").role() ~= "org" then
        die("this instance is not an org central — set MEMO_ROLE=org and MEMO_ORG_NAME")
    end
    local server = require("luamemo.federation.server")
    local ok_bind, why = server.bind_allowed(opts.host)
    if not ok_bind then
        die("federation is local-network only — refusing to bind " .. tostring(opts.host) .. " (" .. tostring(why)
            .. "). Use loopback, a LAN / Tailscale address, or 0.0.0.0.")
    end
    local keys = require("luamemo.federation.keys")
    local pk, kerr = keys.ensure_identity("central")
    if not pk then die("cannot load or create the central identity key: " .. tostring(kerr), 1) end
    -- Public values: devs pin this fingerprint when they pair.
    io.stderr:write(("memo serve: org %s · central fingerprint %s\n")
        :format(tostring(luamemo.config.org_name), keys.fingerprint(pk)))
    local ok_run, rerr = pcall(server.run, opts)
    if not ok_run then die(tostring(rerr), 1) end
end

return M
