-- luamemo.federation.common
-- Small helpers shared by the org central and the dev client.

local M = {}

-- Bump on incompatible wire-format changes: 2 = key-paired encrypted channel;
-- 3 = the same, on libsodium (XChaCha20-Poly1305 frames) — 2 and 3 refuse each other.
M.PROTOCOL = 3
M.EVENT_TYPES = { direct_command = true, mistake = true, reversal = true, praise = true, miss = true }
-- Learned-weight kinds the central ships with a snapshot (learner_store kinds).
M.WEIGHT_KINDS = { "reranker", "projection" }

--- Identify the embedding space: two instances can share raw vectors only when
--- this string matches (same embedder, same model, same dim). Anything else is
--- re-embedded locally, so a mismatch costs time, never correctness.
function M.embedder_sig(cfg)
    cfg = cfg or {}
    local name, model
    if cfg.embedder_local then
        name = cfg.embedder_local
        if name == "gguf_ffi" then
            local p = cfg.embedder_model or os.getenv("MEMO_GGUF_MODEL") or os.getenv("MEMO_GEMMA_MODEL") or ""
            model = p:match("[^/\\]+$") or p
        else
            model = cfg.embedder_model or ""
        end
    else
        name  = cfg.embedder_adapter or "generic"
        model = cfg.embedder_model or ""
    end
    local dim = tonumber(cfg.embed_dim) or ((name == "hash") and 384) or 0
    return ("%s|%s|%d"):format(name, model, dim)
end

--- Constant-time string equality (length leaks, content does not).
function M.secure_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b or #a == 0 then return false end
    -- Branch-free: sum of squared byte differences is 0 only when every byte
    -- matches (no bit ops needed — Lua 5.1-clean — and no early exit).
    local diff = 0
    for i = 1, #a do
        local d = a:byte(i) - b:byte(i)
        diff = diff + d * d
    end
    return diff == 0
end

--- Untrusted wire text → trimmed, at most n bytes (on a character boundary); nil when
--- absent / empty.
function M.clip(s, n)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    if s == "" then return nil end
    return require("luamemo.util").cut_utf8(s, n)
end

--- A vector as the (embedding blob, norm) pair an INSERT binds — nil, nil without one.
function M.vec_params(v)
    if type(v) ~= "table" or #v == 0 then return nil, nil end
    local blob, norm = require("luamemo.vectors").pack(v)
    return require("luamemo.db").blob(blob), norm
end

--- Integer ids from an id-list value (a decoded JSON array, or "[1,2,3]" text).
function M.int_array(v)
    local out = {}
    if type(v) == "table" then
        for _, x in ipairs(v) do out[#out + 1] = tonumber(x) end
    elseif type(v) == "string" then
        for x in v:gmatch("%-?%d+") do out[#out + 1] = tonumber(x) end
    end
    return out
end

--- The memories an earlier copy brought from a source (export import, adopt): metadata[key]
--- = "<tag>:<source id>" → { [source id] = id here }. conn: the database handle to read.
function M.origin_map(conn, key, tag)
    local map, path = {}, "$." .. key
    for _, r in ipairs(conn.query(("SELECT id, json_extract(metadata, '%s') AS o FROM lm_memories "
        .. "WHERE substr(json_extract(metadata, '%s'), 1, ?) = ?"):format(path, path), #tag + 1, tag .. ":") or {}) do
        local old = tonumber((r.o or ""):match(":(%d+)$"))
        if old then map[old] = tonumber(r.id) end
    end
    return map
end

--- The address group a peer's limits are counted per: an IPv4 address as is
--- (IPv4-mapped IPv6 too), an IPv6 address by its /64 — a host can pick any
--- address in its own /64, so counting per address there would count nothing.
--- nil (no peer known, e.g. in-process calls) → nil.
function M.peer_group(ip)
    if type(ip) ~= "string" or ip == "" then return nil end
    if not ip:find(":", 1, true) then return ip end
    local g = require("luamemo.netguard")._parse_v6(ip)
    if not g then return ip end
    if g[1] == 0 and g[2] == 0 and g[3] == 0 and g[4] == 0 and g[5] == 0 and g[6] == 0xffff then
        return ("%d.%d.%d.%d"):format(math.floor(g[7] / 256), g[7] % 256, math.floor(g[8] / 256), g[8] % 256)
    end
    return ("%x:%x:%x:%x::/64"):format(g[1], g[2], g[3], g[4])
end

--- Digest of a replica manifest — { { id, updated_us }, … } in any order — so an
--- up-to-date dev and the central can agree without shipping the list.
function M.manifest_digest(entries)
    local lines = {}
    for i, e in ipairs(entries or {}) do
        lines[i] = ("%d:%d"):format(tonumber(e[1]) or 0, tonumber(e[2]) or 0)
    end
    table.sort(lines)
    local util = require("luamemo.util")
    return util.to_hex(require("luamemo.native.sodium").sha256(table.concat(lines, "\n")))
end

return M
