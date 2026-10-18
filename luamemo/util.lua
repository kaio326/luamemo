-- luamemo.util
-- Shared helpers used across multiple modules.

local M = {}

--- Truncate a string to at most n bytes (on a character boundary: cut_utf8), appending a
--- UTF-8 horizontal ellipsis (U+2026) if the string was clipped. "" for non-string input.
function M.clip(s, n)
    if type(s) ~= "string" then return "" end
    if #s <= n then return s end
    return M.cut_utf8(s, n) .. "\xe2\x80\xa6"
end

--- The first `n` bytes of `s` or fewer, never ending inside a UTF-8 character (a cut
--- there leaves bytes that aren't text: JSON parsers refuse them). `s` itself when it is
--- no longer than `n`.
function M.cut_utf8(s, n)
    if #s <= n then return s end
    while n > 0 and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
    return s:sub(1, n)
end

--- `s` as valid UTF-8: every byte that isn't part of a well-formed character (RFC 3629:
--- no overlong forms, surrogates or values past U+10FFFF) becomes U+FFFD. ASCII text is
--- returned as it is, unscanned. For what is sent out (MCP), whatever is stored.
function M.fix_utf8(s)
    if type(s) ~= "string" or not s:find("[\128-\255]") then return s end
    local out, i, n, last = {}, 1, #s, 1
    while i <= n do
        local c, len = s:byte(i), 0
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4 end
        local ok = len > 0 and i + len - 1 <= n
        if ok and len > 1 then
            local lo, hi = 0x80, 0xBF   -- the second byte's range (narrower after E0 / ED / F0 / F4)
            if c == 0xE0 then lo = 0xA0 elseif c == 0xED then hi = 0x9F
            elseif c == 0xF0 then lo = 0x90 elseif c == 0xF4 then hi = 0x8F end
            local c2 = s:byte(i + 1)
            ok = c2 >= lo and c2 <= hi
            for k = 2, len - 1 do
                local ck = s:byte(i + k)
                if ck < 0x80 or ck > 0xBF then ok = false end
            end
        end
        if ok then
            i = i + len
        else
            out[#out + 1] = s:sub(last, i - 1) .. "\239\191\189"
            i = i + 1
            last = i
        end
    end
    if last == 1 then return s end
    out[#out + 1] = s:sub(last)
    return table.concat(out)
end

--- Strip leading and trailing whitespace from a string.
--- Returns "" for non-string input.
function M.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- ---------------------------------------------------------------------------
-- Time. Stored timestamps are integer microseconds since the Unix epoch (UTC);
-- us_to_iso() renders them the way Postgres used to ("2026-10-08 03:03:14.831072+00").
-- ---------------------------------------------------------------------------
local _now_us
do
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "typedef struct { long tv_sec; long tv_nsec; } lm_util_ts; int clock_gettime(int, lm_util_ts *);")
        local ts = ffi.new("lm_util_ts[1]")
        _now_us = function()
            ffi.C.clock_gettime(0, ts)   -- CLOCK_REALTIME
            return tonumber(ts[0].tv_sec) * 1000000 + math.floor(tonumber(ts[0].tv_nsec) / 1000)
        end
    else
        local okso, socket = pcall(require, "socket")
        _now_us = function()
            return okso and math.floor(socket.gettime() * 1000000) or os.time() * 1000000
        end
    end
end

--- Current time in integer microseconds since the epoch (UTC).
function M.now_us() return _now_us() end

-- Days from 1970-01-01 to y-m-d (proleptic Gregorian; H. Hinnant's days_from_civil).
local function days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- The times luamemo takes: years 1000–9999 — what os.date writes as four digits and
-- iso_to_us reads back (a nanosecond count read as seconds is ~1.8e18: os.date gave nil,
-- and every read of that row raised).
local MIN_SEC, MAX_SEC = -30610224000, 253402300799   -- 1000-01-01 · 9999-12-31 23:59:59 UTC
--- Is this µs time one luamemo takes (years 1000–9999)?
function M.us_in_range(us)
    us = tonumber(us)
    return us ~= nil and us >= MIN_SEC * 1000000 and us < (MAX_SEC + 1) * 1000000
end

--- Integer µs → "YYYY-MM-DD HH:MM:SS.ffffff+00" (UTC) | nil (none, or a time it can't show)
function M.us_to_iso(us)
    us = tonumber(us)
    if not us then return nil end
    local sec = math.floor(us / 1000000)
    local d = os.date("!%Y-%m-%d %H:%M:%S", sec)
    if not d then return nil end
    return d .. (".%06d+00"):format(us - sec * 1000000)
end

--- A row's µs time columns (`keys`) as text, in place → r
function M.iso_fields(r, keys)
    if type(r) ~= "table" then return r end
    for _, k in ipairs(keys) do
        if type(r[k]) == "number" then r[k] = M.us_to_iso(r[k]) end
    end
    return r
end

--- Parse a timestamp → integer µs | nil, err.
-- Accepts a number (epoch SECONDS), "YYYY-MM-DD" (midnight UTC), or
-- "YYYY-MM-DD[T ]HH:MM[:SS[.fraction]]" with an optional "Z" / "+HH[:MM]" / "-HH[:MM]"
-- (no zone = UTC). Years 1000–9999 only (M.us_in_range).
local RANGE_ERR = "out of range (years 1000–9999; epoch seconds, not milli- or nanoseconds): "
function M.iso_to_us(v)
    if type(v) == "number" then
        local us = math.floor(v * 1000000)
        if not M.us_in_range(us) then return nil, RANGE_ERR .. tostring(v) end
        return us
    end
    if type(v) ~= "string" then return nil, "not a timestamp" end
    local s = M.trim(v)
    local y, mo, d, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    if not y then return nil, "expected YYYY-MM-DD[THH:MM[:SS[.ffffff]]][Z|±HH:MM], got " .. v end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo < 1 or mo > 12 or d < 1 or d > 31 then return nil, "invalid date: " .. v end
    local hh, mi, ss, frac, zone = 0, 0, 0, "", ""
    if rest ~= "" then
        local h2, m2, tail = rest:match("^[T ](%d%d):(%d%d)(.*)$")
        if not h2 then return nil, "invalid time in " .. v end
        hh, mi = tonumber(h2), tonumber(m2)
        local s2, tail2 = tail:match("^:(%d%d)(.*)$")
        if s2 then ss, tail = tonumber(s2), tail2 end
        local f2, tail3 = tail:match("^%.(%d+)(.*)$")
        if f2 then frac, tail = f2, tail3 end
        zone = tail
        if hh > 23 or mi > 59 or ss > 60 then return nil, "invalid time in " .. v end
    end
    local off = 0
    if zone ~= "" and zone ~= "Z" and zone ~= "z" then
        local sign, zh, zm = zone:match("^%s*([%+%-])(%d%d):?(%d?%d?)$")
        if not sign then return nil, "invalid time zone in " .. v end
        off = (tonumber(zh) * 3600 + (tonumber(zm) or 0) * 60) * (sign == "+" and 1 or -1)
    end
    local secs = days_from_civil(y, mo, d) * 86400 + hh * 3600 + mi * 60 + ss - off
    local us = secs * 1000000 + (frac ~= "" and tonumber((frac .. "000000"):sub(1, 6)) or 0)
    if not M.us_in_range(us) then return nil, RANGE_ERR .. v end
    return us
end

--- Read a file and return its contents, or nil if the file cannot be opened.
function M.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

--- Coerce a value to boolean.
--- "true"/"1" → true, "false"/"0" → false, booleans pass through, else nil.
function M.to_bool(v)
    if type(v) == "boolean" then return v end
    if v == "true"  or v == "1" then return true  end
    if v == "false" or v == "0" then return false end
    return nil
end

--- Load a sub-module by directory prefix and name, caching the result in
--- the provided cache table.  The loaded module must expose `required_fn`.
--- Returns module, nil on success or nil, err on failure.
--- @param cache       table   caller-owned cache: { [name] = module }
--- @param pkg_prefix  string  e.g. "luamemo.rerankers"
--- @param name        string  adapter name, e.g. "ollama"
--- @param required_fn string  method that must exist on the module
function M.load_submodule(cache, pkg_prefix, name, required_fn)
    name = name or "noop"
    if cache[name] then return cache[name] end
    local ok, mod = pcall(require, pkg_prefix .. "." .. name)
    if not ok then
        return nil, pkg_prefix .. ": adapter not found: " .. name
            .. " (" .. tostring(mod) .. ")"
    end
    if type(mod[required_fn]) ~= "function" then
        return nil, pkg_prefix .. ": adapter '" .. name
            .. "' missing " .. required_fn .. "()"
    end
    cache[name] = mod
    return mod
end

--- Check an HTTP response (status, body, err) from luamemo.http.request.
--- Returns nil, errmsg on failure/non-2xx; otherwise returns true.
--- @param status     number|nil  HTTP status code, or nil on transport error
--- @param body       string|nil  response body
--- @param err        string|nil  transport error string
--- @param ctx        string      human-readable context for error messages
function M.check_http(status, body, err, ctx)
    if not status then
        return nil, ctx .. ": HTTP error: " .. tostring(err)
    end
    if status >= 300 then
        return nil, ctx .. ": HTTP " .. status .. ": " .. tostring(body)
    end
    return true
end

--- Validate that a numeric value is within [lo, hi].
--- Returns the coerced number (or nil when val is nil/not provided),
--- plus an error string on failure.
function M.clamp_check(name, val, lo, hi)
    if val == nil then return nil, nil end
    local n = tonumber(val)
    if not n then
        return nil, name .. " must be a number, got: " .. tostring(val)
    end
    if n < lo or n > hi then
        return nil, ("%s must be between %g and %g, got %g"):format(name, lo, hi, n)
    end
    return n, nil
end

--- Hide URL credentials in messages / logs: user:password@ → user:***@, and a
--- bare userinfo (often a token: https://TOKEN@host) → ***@. The userinfo runs
--- to the LAST "@" before the path, so a raw "@" in a password can't leak a tail.
-- Query parameters that carry credentials (?key=…, &access_token=…): their values are
-- masked too.
-- A name is one of the words, ends in one after a separator (api_key, x-api-key,
-- client.secret), or is a known compound (apikey, accesstoken) — not any name holding
-- the letters (keyword, monkey).
local CREDENTIAL_PARAMS = { "key", "token", "secret", "password", "passwd", "pwd", "auth",
    "signature", "sig", "credential", "credentials" }
local CREDENTIAL_COMPOUNDS = { apikey = true, accesstoken = true, authtoken = true, sessiontoken = true }

-- Is `name` (lower case) a compound or one of `words`, or does it end in one after a
-- separator (api_key, x-api-key, client.secret)?
local function name_in(name, words)
    if CREDENTIAL_COMPOUNDS[name] then return true end
    for _, w in ipairs(words) do
        if name == w then return true end
        local before = name:sub(-#w - 1, -#w - 1)
        if #name > #w and name:sub(-#w) == w and (before == "_" or before == "-" or before == ".") then
            return true
        end
    end
    return false
end
local function credential_param(name) return name_in(name:lower(), CREDENTIAL_PARAMS) end

function M.redact_url(s)
    s = tostring(s or ""):gsub("//([^/%s]*)@", function(userinfo)
        local user = userinfo:match("^([^:@]*):")
        return "//" .. (user and (user .. ":***") or "***") .. "@"
    end)
    return (s:gsub("([?&])([%w_%-%.]+)=([^&#%s]*)", function(sep, name, value)
        if value ~= "" and credential_param(name) then return sep .. name .. "=***" end
        return sep .. name .. "=" .. value
    end))
end

-- Credentials of an unmistakable shape: private-key blocks (also one cut off), JWTs,
-- Bearer / Basic credentials, tokens with a known prefix (sk-, ghp_, glpat-, xoxb-, …)
-- and AWS access key ids. One list for both of their users: the scrubber below and the
-- org-proposal filter (has_token) — a format added here is scrubbed and flagged.
local TOKEN_PREFIXES = { "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "ghp_", "gho_", "ghu_",
    "ghs_", "ghr_", "github_pat_", "glpat-", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-", "AIza",
    "npm_", "hf_", "pypi-", "dop_v1_", "shpat_" }
local KEY_BEGIN = "%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY[%u ]*"

local function token_like(w)
    -- AKIA (long-term) / ASIA (temporary) + 16 upper-case letters or digits, also glued
    -- to other text; an ASIA one only with a digit among them (ASIAPACIFIC… is a word).
    local aws = w:match("A[KS]IA" .. ("[%u%d]"):rep(16))
    if aws and (aws:sub(2, 2) == "K" or aws:find("%d", 5)) then return true end
    if not (w:find("%d") or #w >= 32) then return false end              -- random ones hold a digit
    for _, p in ipairs(TOKEN_PREFIXES) do
        if w:sub(1, #p) == p then return true end
    end
    return false
end

local function scrub_tokens(s)
    local function keep_prefix(min)
        return function(pre, t) if #t >= min then return pre .. "[redacted]" end end
    end
    return (s:gsub(KEY_BEGIN .. "%-%-%-%-%-.-%-%-%-%-%-END [%u ]*PRIVATE KEY[%u ]*%-%-%-%-%-", "[redacted]")
        :gsub(KEY_BEGIN .. "%-*[%w%+/=%s]*", "[redacted]")              -- one cut off
        :gsub("eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]+", "[redacted]")         -- a JWT
        :gsub("([Bb]earer%s+)([%w%-%._~%+/]+=*)", keep_prefix(16))
        :gsub("([Aa]uthorization:%s*[Bb]asic%s+)([%w%+/]+=*)", keep_prefix(8))
        :gsub("%f[%w_%-]" .. ("[%w_%-]"):rep(20) .. "[%w_%-]*", function(w)
            if token_like(w) then return "[redacted]" end
        end))
end

--- Does `s` hold a credential of an unmistakable shape (the list above)? The
--- org-proposal filter's check — it adds its own, broader ones.
function M.has_token(s)
    return type(s) == "string" and s ~= "" and scrub_tokens(s) ~= s
end

--- `s` with what looks like a credential replaced by [redacted]. Every memory is scrubbed
--- before it is stored (owner, 2026-10-16): a key pasted into the chat would otherwise be
--- saved by the session hooks and come back in searches. The shapes above, URL credentials
--- (redact_url) and `password = …`-style assignments whose value mixes letters and digits.
--- Commit SHAs, UUIDs and code such as `token = args.token` are left alone (unlike the
--- proposal filter, a false alarm here changes what is stored). Linear in the text's length.
local SECRET_NAMES = { "password", "passwd", "secret", "token", "credentials", "api_key", "api-key",
    "access_key", "private_key" }   -- and the compounds (apikey, accesstoken, …)

-- An assignment's value that reads like a password, not code: 8+ characters mixing
-- letters and digits, no $VARIABLE, no dotted / underscored identifier.
local function secret_value(v)
    return #v >= 8 and v:find("%a") ~= nil and v:find("%d") ~= nil and not v:find("^%$")
        and not v:match("^[%a_][%w_]*[_%.][%w_%.]*$")
end

function M.redact_secrets(s)
    if type(s) ~= "string" or s == "" then return s end
    s = scrub_tokens(s)
        :gsub("%f[%w_%-%.]([%w_%-%.]+)([\"']?%s*[:=]%s*[\"']?)([^%s\"'`,;&<>(){}%[%]]+)", function(name, sep, v)
            if secret_value(v) and name_in(name:lower(), SECRET_NAMES) then return name .. sep .. "[redacted]" end
        end)
    return (M.redact_url(s))
end

--- Shell-safe single-quote a value for use in os.execute() / io.popen() calls.
--- Wraps the value in single quotes, escaping any embedded single quotes
--- using the standard POSIX idiom  '  →  '\''  so the shell sees them
--- as a literal apostrophe.
--- @param s  any  Value to quote (coerced to string)
--- @return string
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- A command's output (stderr dropped, trailing whitespace trimmed), "" when it can't run.
function M.sh(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return (out:gsub("%s+$", ""))
end

--- An environment variable's value; nil when it is unset or empty.
function M.env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

--- The canonical path of an existing file or directory (symlinks and ".." resolved) | nil
--- — false where libc has no realpath(3).
local _has_realpath
function M.realpath(p)
    if type(p) ~= "string" or p == "" then return nil end
    local ffi = require("luamemo.native.loader").ffi
    if _has_realpath == nil then
        pcall(ffi.cdef, "char *realpath(const char *path, char *resolved);")
        pcall(ffi.cdef, "void free(void *ptr);")
        _has_realpath = pcall(function() return ffi.C.realpath end)
    end
    if not _has_realpath then return false end
    local r = ffi.C.realpath(p, nil)
    if r == nil then return nil end
    local s = ffi.string(r)
    ffi.C.free(r)
    return s
end

--- A directory's absolute, symlink-free path (as `pwd -P` gives it), or nil. (realpath(3):
--- it forked a shell per call — three per secret_execute upload, one per settings check.)
function M.real_dir(dir)
    if type(dir) ~= "string" or dir == "" then return nil end
    local p = M.realpath((dir:gsub("/+$", "")) .. "/.")   -- (".../." resolves for a directory only)
    if p == false then
        local out = M.sh("cd " .. M.shell_quote(dir) .. " && pwd -P")
        return out ~= "" and out or nil
    end
    return p
end

--- Does a file exist and open for reading?
function M.exists(p)
    local f = type(p) == "string" and p ~= "" and io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

--- Is the path a directory?
function M.is_dir(p)
    if type(p) ~= "string" or p == "" then return false end
    local r = os.execute("test -d " .. M.shell_quote(p))
    return r == 0 or r == true
end

-- libc, when LuaJIT's FFI is available (mkdir / chmod / umask). nil otherwise — the
-- callers below fall back to shelling out.
local _libc
local function libc()
    if _libc == nil then
        local ok, ffi = pcall(require, "ffi")
        _libc = false
        if ok then
            -- (one by one: a declaration made elsewhere first doesn't stop the others)
            pcall(ffi.cdef, "int mkdir(const char *path, unsigned int mode);")
            pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")
            pcall(ffi.cdef, "unsigned int umask(unsigned int mask);")
            _libc = ffi.C
        end
    end
    return _libc or nil
end

--- fn(...) with the process umask at `mask` (octal text: "077"), restored after — also when
--- fn raises → fn's results. Without the FFI fn just runs (umask as it was).
function M.with_umask(mask, fn, ...)
    local C = libc()
    if not C then return fn(...) end
    local old = C.umask(tonumber(mask, 8))
    local res = (function(...) return { n = select("#", ...), ... } end)(pcall(fn, ...))
    C.umask(old)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

--- Create a directory and its missing parents; a directory created here is 0700, and
--- with `own` (luamemo's own: the keyring, the vault key) an existing one is made 0700
--- too. Otherwise a directory that already exists is left as it is — a database's
--- directory may be /tmp, a project or a shared folder, never luamemo's to lock down.
function M.private_dir(dir, own)
    if type(dir) ~= "string" or dir == "" then return end
    local C = libc()
    if not C then
        local q = M.shell_quote(dir)
        os.execute(("[ -d %s ] || { mkdir -p %s && chmod 700 %s; }"):format(q, q, q))
        if own then os.execute("chmod 700 " .. q) end
        return
    end
    local parts, path = {}, (dir:sub(1, 1) == "/" and "" or ".")
    for part in dir:gmatch("[^/]+") do parts[#parts + 1] = part end
    for i, part in ipairs(parts) do
        path = path .. "/" .. part
        local last = i == #parts
        -- Created parents keep normal permissions (they may be shared, e.g. ~/.local/share);
        -- only the directory itself is 0700 — and exactly 0700 when luamemo created it
        -- (mkdir returns 0), whatever the umask.
        if C.mkdir(path, tonumber(last and "700" or "755", 8)) == 0 and last then
            C.chmod(path, tonumber("700", 8))
        end
    end
    if own then C.chmod(dir, tonumber("700", 8)) end
end

--- n random bytes as 2n hex digits: /dev/urandom, else math.random (never for keys — the
--- vault's and the federation's come from libsodium; this names files and databases).
function M.random_hex(n)
    local f = io.open("/dev/urandom", "rb")
    local raw = f and f:read(n)
    if f then f:close() end
    if not raw or #raw ~= n then
        local bytes = {}
        for i = 1, n do bytes[i] = string.char(math.random(0, 255)) end
        raw = table.concat(bytes)
    end
    return M.to_hex(raw)
end

local _tmp_seq = 0
--- Write `data` to `path` so no one but the owner can read it, even for an instant: a
--- 0600 temp file in the same directory (created with the mode, not chmod'd after),
--- then renamed over `path`. The parent directory is created 0700 if missing. Anything
--- at `path` is replaced — a symlink too, unless `opts.follow_link` (the user's own
--- ~/.luamemorc, which a dotfiles manager may link): then a link to this user's own
--- file is written where it points, so it survives. Never for a project's settings file:
--- a downloaded folder could link it to any file of the user's. On a failure nothing is
--- left behind. → true | nil, err.
function M.write_private(path, data, opts)
    if type(path) ~= "string" or path == "" then return nil, "write_private: a path is required" end
    if opts and opts.follow_link then
        local q = M.shell_quote(path)
        local target = M.sh(("(test -L %s && t=$(readlink -f %s) && test -f \"$t\" && test -O \"$t\" "
            .. "&& printf %%s \"$t\")"):format(q, q))
        if target ~= "" then path = target end
    end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then M.private_dir(dir) end
    -- A random name: in a shared directory nobody can plant a link under it beforehand.
    _tmp_seq = _tmp_seq + 1
    local tmp = ("%s.tmp.%s%d"):format(path, M.random_hex(8), _tmp_seq)
    os.remove(tmp)   -- a leftover would keep its old mode through io.open
    -- new files: 0666 & ~0177 = 0600 (no FFI: pre-created 0600, then the open truncates)
    if not libc() then os.execute("umask 177 && : > " .. M.shell_quote(tmp)) end
    local f = M.with_umask("177", io.open, tmp, "w")
    if not f then return nil, "write_private: cannot write " .. tmp end
    f:write(data or "")
    f:close()
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, "write_private: cannot replace " .. path
    end
    return true
end

--- Validate that a value is a non-empty string.
--- Returns the value on success, or nil plus an error message on failure.
--- Follows the same (value, err) convention as the rest of the library.
--- @param v     any     Value to check
--- @param name  string  Field name used in the error message
--- @return string|nil, string|nil
function M.require_str(v, name)
    if type(v) ~= "string" or v == "" then
        return nil, (name or "value") .. " is required (non-empty string)"
    end
    return v
end

--- Parse a { scores = [{index, score}, ...] } LLM response table into a
--- normalised output array.  Used by the ollama and openai reranker adapters.
--- @param tbl  table  the `scores` array from the decoded LLM response
--- @return table      array of { index = number, score = number }
function M.parse_scores(tbl)
    local out = {}
    for _, s in ipairs(tbl) do
        out[#out + 1] = {
            index = tonumber(s.index),
            score = tonumber(s.score) or 0,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Shared math / ML helpers
-- ---------------------------------------------------------------------------

--- Cosine similarity over two Lua numeric arrays.
--- Returns 0 for nil, non-table, or zero-magnitude input.
--- Handles mismatched lengths by using the shorter of the two.
--- @param a  table  numeric array
--- @param b  table  numeric array
--- @return number  value in [0, 1]
function M.cosine(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return 0 end
    local dot, na, nb = 0, 0, 0
    local len = math.min(#a, #b)
    if len == 0 then return 0 end
    for i = 1, len do
        local ai, bi = tonumber(a[i]) or 0, tonumber(b[i]) or 0
        dot = dot + ai * bi
        na  = na  + ai * ai
        nb  = nb  + bi * bi
    end
    local denom = math.sqrt(na) * math.sqrt(nb)
    if denom == 0 then return 0 end
    return dot / denom
end

--- Greedy single-linkage cosine clustering.
--- Assigns each memory to the first existing cluster whose pivot has
--- cosine similarity >= threshold; otherwise starts a new cluster.
--- Memories without a table-type embedding are placed in singleton clusters.
--- @param memories   table  array of rows; each may have an `.embedding` field
--- @param threshold  number cosine similarity cutoff (e.g. 0.80)
--- @return table  array of clusters; each cluster is an array of memory rows
function M.cluster(memories, threshold)
    local clusters = {}
    local pivots   = {}
    for _, mem in ipairs(memories) do
        local vec = type(mem.embedding) == "table" and mem.embedding or nil
        local assigned = false
        if vec then
            for ci = 1, #clusters do
                if M.cosine(pivots[ci], vec) >= threshold then
                    local cl = clusters[ci]
                    cl[#cl + 1] = mem
                    assigned = true
                    break
                end
            end
        end
        if not assigned then
            clusters[#clusters + 1] = { mem }
            pivots[#pivots + 1]     = vec
        end
    end
    return clusters
end

--- Derive a memory tier (0–3) from an importance value, on importance's own
--- 0–10 scale (default 1.0 = a normal memory → tier 1):
---   < 0.3 → 0 (ephemeral events) · < 5 → 1 · < 9 → 2 · ≥ 9 → 3.
--- Used when a write gives no explicit tier; promotion (digest) then moves a
--- memory up as it proves itself. (Before migration 017 the thresholds were
--- 0.3 / 0.6 / 0.85, so a default write landed in tier 3.)
--- @param imp  number  importance value (0.0 – 10.0)
--- @return number  tier integer 0–3
function M.importance_to_tier(imp)
    local v = tonumber(imp) or 0
    if v < 0.3 then return 0 end
    if v < 5   then return 1 end
    if v < 9   then return 2 end
    return 3
end

-- Module-level cache shared by util.table_exists across all callers in the
-- same Lua VM.  Deliberately never invalidated at runtime (see docs).
local _table_ok_cache = {}

--- Check whether a table exists in the configured database.
--- Results are cached permanently within the process lifetime.
--- Requires luamemo.db to be available (called lazily to avoid a circular
--- require at load time).
--- @param name  string  unquoted table name
--- @return boolean
function M.table_exists(name)
    if _table_ok_cache[name] then return true end
    local db = require("luamemo.db")
    if db.value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name) then
        _table_ok_cache[name] = true
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- DJB2 polynomial hash (pure Lua 5.1, no bit library) mod 2^32. The project's
-- checksum of choice for change-detection and dedup markers. NOTE: this is NOT
-- the embedder's hash (luamemo.embedders.hash uses a different modulus and must
-- stay byte-stable for stored embeddings — do not route it through here).
-- ---------------------------------------------------------------------------
local _DJB2_MASK = 4294967296  -- 2^32

function M.djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % _DJB2_MASK end
    return h
end

-- Zero-padded 8-char lowercase hex of djb2(s).
function M.djb2_hex(s)
    return ("%08x"):format(M.djb2(s))
end

--- Bytes → lowercase hex; hex → bytes (nil when not even-length hex).
function M.to_hex(s)
    return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end
function M.from_hex(h)
    if type(h) ~= "string" or #h % 2 ~= 0 or h:find("%X") then return nil end
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

return M
