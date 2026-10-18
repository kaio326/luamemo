-- eval/tests/test_index_walker.lua
-- Walker safety + scoping (pure, no DB except test 6):
--   1. walker.is_secret classifies credential files and leaves normal files alone
--   2. A walk never returns credential files, even with an empty exclude list
--   3. Exclude patterns match as prefix / substring / glob — never as a subsequence
--   4. Inside a git work tree gitignored files are skipped; tracked (even if
--      ignored), untracked-unignored and submodule files are kept; a root that is
--      itself gitignored is walked unfiltered; respect_gitignore=false restores
--      ignored files (credentials are skipped in every case)
--   5. Outside a git work tree nothing is filtered by .gitignore
--   5b. The lfs and find backends return the same files (when luafilesystem is installed)
--   6. CLI: --exclude ADDS to the defaults (needs MEMO_DB; skipped otherwise)
--
-- Run: luajit eval/tests/run.lua --only index_walker

package.path = "./?/init.lua;./?.lua;" .. package.path

local walker = require("luamemo.index.walker")

local PASS, FAIL = 0, 0
local function pass(m) PASS = PASS + 1; io.write("[PASS] " .. m .. "\n") end
local function fail(m) FAIL = FAIL + 1; io.write("[FAIL] " .. m .. "\n") end
local function info(m) io.write("[INFO] " .. m .. "\n") end

local function sh(cmd)
    local p = assert(io.popen(cmd .. " 2>&1"))
    local out = p:read("*a") or ""
    p:close()
    return out
end
local q = require("luamemo.util").shell_quote

local function write(root, rel, body)
    sh("mkdir -p " .. q((root .. "/" .. rel):match("^(.*)/[^/]*$")))
    local f = assert(io.open(root .. "/" .. rel, "w"))
    f:write(body or "x = 1\n")
    f:close()
end

local function relset(files)
    local s = {}
    for _, f in ipairs(files or {}) do s[(f.rel:gsub("\\", "/"))] = true end
    return s
end

-- expect(set, rel, want, label): want=true → rel must be walked, false → skipped.
local function expect(set, rel, want, label)
    if (set[rel] == true) == want then pass(label .. ": " .. rel)
    else fail(label .. ": " .. rel .. (want and " was skipped" or " was walked")) end
end

local tmp_dirs = {}
local function tmpdir()
    local d = sh("mktemp -d"):gsub("%s+$", "")
    tmp_dirs[#tmp_dirs + 1] = d
    return d
end

-- ---------------------------------------------------------------------------
io.write("\n--- Test 1: is_secret classification ---\n")
-- ---------------------------------------------------------------------------
for _, rel in ipairs({
    ".env", "app/.env", ".env.local", ".env.production", ".envrc", ".luamemorc",
    "sub/.memorc", ".pgpass", ".netrc", ".npmrc", ".pypirc", ".htpasswd",
    ".git-credentials", "certs/server.pem", "tls/private.KEY", "keystore.jks",
    "id_rsa", "home/id_ed25519", ".ssh/config", "deploy/.aws/credentials",
    ".gnupg/pubring.kbx", "secrets/lm_master_key.txt",
}) do
    if walker.is_secret(rel) then pass("secret: " .. rel) else fail("NOT flagged as secret: " .. rel) end
end
for _, rel in ipairs({
    ".env.example", ".env.sample", ".env.template", "config/.env.dist", "src/env.lua",
    "environment.lua", "src/.environment", "id_rsa.pub", "keys.lua", "docs/ssh.md",
    "monkey.lua", "README.md", "luamemo/secrets.lua",
}) do
    if not walker.is_secret(rel) then pass("not secret: " .. rel) else fail("wrongly flagged as secret: " .. rel) end
end

-- ---------------------------------------------------------------------------
io.write("\n--- Test 2: credential files are never walked ---\n")
-- ---------------------------------------------------------------------------
local plain = tmpdir()   -- NOT a git work tree
write(plain, "src/app.lua", "local M = {}\nreturn M\n")
write(plain, "README.md", "# demo\n")
write(plain, ".env", "OPENAI_API_KEY=sk-FAKE\n")
write(plain, ".env.example", "OPENAI_API_KEY=\n")
write(plain, ".luamemorc", "MEMO_DB='app'\nMEMO_MASTER_KEY='0000000000000000000000000000000000000000000000000000000000000000'\n")
write(plain, "config/.env.production", "DB_PASSWORD=pw\n")
write(plain, "certs/server.pem", "-----BEGIN PRIVATE KEY-----\n")
write(plain, ".ssh/id_ed25519", "-----BEGIN OPENSSH PRIVATE KEY-----\n")
write(plain, ".gitignore", "build/\n")
write(plain, "build/out.lua", "return 1\n")

local s2 = relset(walker.walk(plain, { extensions = "*", exclude_patterns = {} }))
expect(s2, "src/app.lua",            true,  "normal file kept")
expect(s2, "README.md",              true,  "normal file kept")
expect(s2, ".env.example",           true,  "env template kept")
expect(s2, ".env",                   false, "credential skipped")
expect(s2, ".luamemorc",             false, "credential skipped")
expect(s2, "config/.env.production", false, "credential skipped")
expect(s2, "certs/server.pem",       false, "credential skipped")
expect(s2, ".ssh/id_ed25519",        false, "credential dir skipped")

-- ---------------------------------------------------------------------------
io.write("\n--- Test 3: exclude patterns are prefix/substring/glob, not subsequence ---\n")
-- ---------------------------------------------------------------------------
write(plain, "lib/sensing/init.lua")
write(plain, "lib/vendor/dep.lua")
write(plain, "lib/vendored_notes.lua")
write(plain, "web/app.min.js", "a()\n")
write(plain, "web/app.js", "a()\n")
write(plain, "a/b/generated/x.lua")
write(plain, "a/generated/sub/y.lua")

local s3 = relset(walker.walk(plain, { extensions = "*",
    exclude_patterns = { ".git", "vendor/", "*.min.js", "**/generated/*.lua" } }))
expect(s3, "lib/sensing/init.lua",   true,  "'.git' is not a g…i…t subsequence")
expect(s3, "lib/vendor/dep.lua",     false, "'vendor/' substring excludes")
expect(s3, "lib/vendored_notes.lua", true,  "'vendor/' needs the slash")
expect(s3, "web/app.min.js",         false, "'*.min.js' glob excludes")
expect(s3, "web/app.js",             true,  "'*.min.js' glob is specific")
expect(s3, "a/b/generated/x.lua",    false, "'**/generated/*.lua' excludes a direct child")
expect(s3, "a/generated/sub/y.lua",  true,  "'*' does not cross '/'")

-- ---------------------------------------------------------------------------
io.write("\n--- Test 4: gitignore inside a git work tree ---\n")
-- ---------------------------------------------------------------------------
local have_git = sh("git --version"):match("^git version") ~= nil
local repo
if not have_git then
    info("git not available — skipping gitignore tests")
else
    repo = tmpdir()
    local git = "git -C " .. q(repo) .. " -c user.name=t -c user.email=t@t "
    sh(git .. "init -q")
    write(repo, ".gitignore", "build/\n*.log\nlocal.cfg\n")
    write(repo, "src/main.lua", "return 1\n")
    write(repo, "notes.txt", "todo\n")
    write(repo, "build/out.lua", "return 2\n")
    write(repo, "debug.log", "trace\n")
    write(repo, "local.cfg", "tracked_but_ignored = true\n")
    write(repo, ".env", "SECRET=1\n")
    -- embedded repo registered as a gitlink (how a submodule appears to ls-files)
    write(repo, "sub/lib.lua", "return 3\n")
    sh("git -C " .. q(repo .. "/sub") .. " init -q")
    sh("git -C " .. q(repo .. "/sub") .. " -c user.name=t -c user.email=t@t add -A")
    sh("git -C " .. q(repo .. "/sub") .. " -c user.name=t -c user.email=t@t commit -qm init")
    sh(git .. "add src/main.lua sub")
    sh(git .. "add -f local.cfg")

    local walk_opts = { extensions = "*", exclude_patterns = { ".git" } }
    local s4 = relset(walker.walk(repo, walk_opts))
    expect(s4, "src/main.lua",  true,  "tracked file kept")
    expect(s4, "notes.txt",     true,  "untracked, not ignored → kept")
    expect(s4, "local.cfg",     true,  "tracked file kept even though it matches .gitignore")
    expect(s4, "sub/lib.lua",   true,  "submodule file kept")
    expect(s4, "build/out.lua", false, "gitignored dir skipped")
    expect(s4, "debug.log",     false, "gitignored file skipped")
    expect(s4, ".env",          false, "credential skipped")

    local s4b = relset(walker.walk(repo .. "/src", walk_opts))
    expect(s4b, "main.lua", true, "walking a repo subdirectory keeps its tracked file")

    write(repo, "build/.env", "SECRET=2\n")
    local s4d = relset(walker.walk(repo .. "/build", walk_opts))
    expect(s4d, "out.lua", true,  "root itself gitignored → explicit choice, not filtered")
    expect(s4d, ".env",    false, "root itself gitignored → credentials still skipped")

    local s4c = relset(walker.walk(repo, { extensions = "*", exclude_patterns = { ".git" },
                                           respect_gitignore = false }))
    expect(s4c, "build/out.lua", true,  "respect_gitignore=false restores ignored files")
    expect(s4c, "debug.log",     true,  "respect_gitignore=false restores ignored files")
    expect(s4c, ".env",          false, "credential still skipped with respect_gitignore=false")
end

-- ---------------------------------------------------------------------------
io.write("\n--- Test 5: outside a git work tree .gitignore is not applied ---\n")
-- ---------------------------------------------------------------------------
expect(s2, "build/out.lua", true, "no git → .gitignore ignored, file kept")

-- ---------------------------------------------------------------------------
io.write("\n--- Test 5b: lfs and find backends walk the same files ---\n")
-- ---------------------------------------------------------------------------
-- The walker prefers luafilesystem and falls back to `find`; a bug in either
-- path is invisible on hosts that only exercise the other (regression: the lfs
-- path dropped lfs.dir's dir object and crashed with luafilesystem >= 1.8).
if not pcall(require, "lfs") then
    info("luafilesystem not installed — skipping backend parity")
else
    local opts = { extensions = "*", exclude_patterns = { ".git" }, respect_gitignore = false }
    local ok_lfs, via_lfs = pcall(walker.walk, plain, opts)
    if ok_lfs and via_lfs then pass("lfs backend walks without error")
    else fail("lfs backend walks without error — " .. tostring(via_lfs)) end

    local saved_loaded, saved_preload = package.loaded.lfs, package.preload.lfs
    package.loaded.lfs = nil
    package.preload.lfs = function() error("lfs disabled for this test") end
    local via_find = walker.walk(plain, opts)
    package.loaded.lfs, package.preload.lfs = saved_loaded, saved_preload

    local a, b = relset(ok_lfs and via_lfs or {}), relset(via_find)
    local diff = {}
    for rel in pairs(a) do if not b[rel] then diff[#diff + 1] = "lfs-only " .. rel end end
    for rel in pairs(b) do if not a[rel] then diff[#diff + 1] = "find-only " .. rel end end
    if #diff == 0 and next(a) then pass("lfs and find return the same file set")
    else fail("lfs and find return the same file set — " .. table.concat(diff, ", ")) end
end

-- ---------------------------------------------------------------------------
io.write("\n--- Test 6: CLI --exclude adds to the defaults ---\n")
-- ---------------------------------------------------------------------------
if not os.getenv("MEMO_DB") then
    io.write("[SKIP] MEMO_DB not set — CLI test skipped\n")
elseif not repo then
    info("no git repo fixture — skipping CLI test")
else
    local out = sh("./cli/memo index ingest --root " .. q(repo)
        .. " --scope codeindex:walkertest --no-gitignore --exclude build/ --dry-run")
    local listed = {}
    for rel in out:gmatch("%] (%S+) →") do listed[rel] = true end
    local git_internals = 0
    for rel in pairs(listed) do
        if rel:match("^%.git/") or rel:match("/%.git/") then git_internals = git_internals + 1 end
    end
    if next(listed) == nil then
        fail("CLI dry-run listed no files — output: " .. out:sub(1, 300))
    else
        if git_internals == 0 then pass("--exclude kept the default '.git' exclude")
        else fail("--exclude replaced the defaults: " .. git_internals .. " .git/ files walked") end
        expect(listed, "build/out.lua", false, "--exclude pattern applied")
        expect(listed, "debug.log",     true,  "--no-gitignore passed through")
    end
end

-- ---------------------------------------------------------------------------
for _, d in ipairs(tmp_dirs) do sh("rm -rf " .. q(d)) end
io.write(("\n=== Walker results: %d passed, %d failed ===\n"):format(PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
