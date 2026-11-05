-- eval/tests/test_agent.lua
-- Phase 23.3 — `memo agent`: luamemo as the agent's memory in Claude Code, set up without hand
-- configuration: the hooks merged into ~/.claude/settings.json (other hooks and keys untouched, a
-- second run changes nothing), a marked block in ~/.claude/CLAUDE.md, the hook scripts copied to
-- a path that survives an upgrade, the project's Claude Code memory notes moved into luamemo,
-- uninstall, status, and the installed hooks working end to end. Every run is in a hermetic HOME.
-- Run: luajit eval/tests/run.lua --only agent

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Agent")
local check, section, finish = T.check, T.section, T.finish
local json = require("luamemo.json")
local q = require("luamemo.util").shell_quote

local REPO = (H.sh("pwd"))
local MEMO = REPO .. "/cli/memo"
local base = os.tmpname(); os.remove(base)
os.execute(("mkdir -p %q"):format(base))
local put = H.write_file
local function slurp(file) return H.slurp(file) or "" end
local lua_dir = H.lua_dir()
local function exists(path) return H.sh(("test -e %q && echo y || echo n"):format(path)) == "y" end

-- A world: a home (with or without ~/.claude), a project, and a way to run memo in them.
local counter = 0
local function world(opts)
    opts = opts or {}
    counter = counter + 1
    local w = { dir = base .. "/w" .. counter }
    w.home, w.proj, w.data = w.dir .. "/home", w.dir .. "/proj", w.dir .. "/data"
    w.claude = w.home .. "/.claude"
    os.execute(("mkdir -p %q %q"):format(w.home, w.proj))
    if opts.claude ~= false then os.execute(("mkdir -p %q"):format(w.claude)) end
    w.settings, w.md = w.claude .. "/settings.json", w.claude .. "/CLAUDE.md"
    w.scope = "repo:agent" .. counter
    function w.run(args)
        return H.sh(("cd %q && env -i HOME=%q PATH=%q XDG_DATA_HOME=%q MEMO_DB=%q MEMO_SCOPE=%s MEMO_EMBEDDER=hash MEMO_PROJECT=%q "
            .. "bash %q agent %s </dev/null"):format(w.proj, w.home, lua_dir .. ":" .. H.sys_path(), w.data, os.getenv("MEMO_DB"), w.scope,
            w.proj, MEMO, args))
    end
    function w.hooks() local d = json.decode(slurp(w.settings)); return d and d.hooks or {} end
    function w.commands(event)
        local out = {}
        for _, entry in ipairs(w.hooks()[event] or {}) do
            for _, hk in ipairs(entry.hooks or {}) do out[#out + 1] = hk.command end
        end
        return out
    end
    function w.ours(event)
        for _, c in ipairs(w.commands(event)) do if c:find("luamemo-agent", 1, true) then return c end end
    end
    -- (Claude Code names the project's directory after its real path — on macOS /tmp is /private/tmp)
    function w.notes_dir()
        local real = H.sh(("cd %q && pwd -P"):format(w.proj))
        return w.claude .. "/projects/" .. real:gsub("[^%w]", "-") .. "/memory"
    end
    return w
end

local ORIGINAL = [[{
  "model": "sonnet",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo other-tool" } ] },
      { "matcher": "Write|Edit", "hooks": [ { "type": "command", "command": "/root/.claude/hooks/block-file-memory.sh" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo done" } ] } ]
  },
  "theme": "auto"
}
]]

-- ---------------------------------------------------------------------------
section("install: merged into settings.json, nothing else disturbed", function()
    local w = world()
    put(w.settings, ORIGINAL); put(w.md, "# my notes\n\nkeep this\n")
    local out, code = w.run("install")
    check("install exits 0 and says what it did", code == 0 and out:find("hooks wired", 1, true) ~= nil
        and out:find("luamemo block written", 1, true) ~= nil, out)
    for _, ev in ipairs({ "SessionStart", "UserPromptSubmit", "PreToolUse" }) do
        local c = w.ours(ev)
        check(ev .. ": wired to a copy of the script in the data directory, pinned to this memo",
            c and c:find(w.data .. "/luamemo/hooks/claude/", 1, true) ~= nil and c:find("MEMO_BIN=", 1, true) ~= nil, c)
    end
    local keys = H.sh(("jq -c 'keys_unsorted' %q"):format(w.settings))
    check("the file's other keys and their order stay (model, hooks, theme)", keys == '["model","hooks","theme"]', keys)
    check("other tools' hooks stay: the Bash PreToolUse and the Stop hook",
        table.concat(w.commands("PreToolUse"), "|"):find("echo other-tool", 1, true) ~= nil and w.commands("Stop")[1] == "echo done")
    check("the earlier hand-made guard is replaced, not duplicated",
        table.concat(w.commands("PreToolUse"), "|"):find("block-file-memory.sh", 1, true) == nil)
    local pre = w.hooks().PreToolUse
    check("the guard has its matcher Write|Edit|NotebookEdit", pre[#pre].matcher == "Write|Edit|NotebookEdit")
    for _, f in ipairs({ "_project.sh", "session_start.sh", "user_prompt.sh", "block_file_memory.sh" }) do
        local copy = w.data .. "/luamemo/hooks/claude/" .. f
        check("the copy of " .. f .. " is the shipped script, executable",
            slurp(copy) == slurp(REPO .. "/hooks/claude/" .. f) and H.sh(("test -x %q && echo x"):format(copy)) == "x")
    end
    local md = slurp(w.md)
    check("CLAUDE.md: the user's text first, then one luamemo block", md:find("^# my notes\n\nkeep this\n") ~= nil
        and select(2, md:gsub("<!%-%- luamemo:begin", "")) == 1 and md:find("memory_sense", 1, true) ~= nil, md)
    check("a backup of the original settings.json is kept", slurp(w.settings .. ".luamemo-bak") == ORIGINAL)

    local s1, c1 = slurp(w.settings), slurp(w.md)
    local out2, code2 = w.run("install")
    check("a second install changes nothing: settings, CLAUDE.md byte for byte; it says so",
        code2 == 0 and slurp(w.settings) == s1 and slurp(w.md) == c1 and out2:find("already wired", 1, true) ~= nil
        and out2:find("0 new or updated", 1, true) ~= nil, out2)
end)

section("install: where it does nothing, or less", function()
    local none = world({ claude = false })
    local out, code = none.run("install")
    check("no ~/.claude (Claude Code is not installed): exit 0, a plain message, nothing created",
        code == 0 and out:find("Claude Code was not found", 1, true) ~= nil
        and H.sh(("ls -A %q"):format(none.home)) == "" and not exists(none.data), out)

    local dry = world()
    local dout, dcode = dry.run("install --dry-run")
    check("--dry-run reports and writes nothing", dcode == 0 and dout:find("[dry-run]", 1, true) ~= nil
        and H.sh(("ls -A %q"):format(dry.claude)) == "" and not exists(dry.data), dout)

    local plug = world()
    put(plug.settings, '{"enabledPlugins": {"luamemo@luamemo": true}}\n')
    local pout = plug.run("install")
    check("the luamemo plugin enabled: it ships the hooks, so none are added; the CLAUDE.md block is",
        pout:find("plugin is enabled", 1, true) ~= nil and next(plug.hooks()) == nil and slurp(plug.md):find("luamemo:begin", 1, true) ~= nil
        and not exists(plug.data .. "/luamemo/hooks"), pout)

    local proj = world()
    os.execute(("mkdir -p %q"):format(proj.proj .. "/.claude"))
    put(proj.proj .. "/.claude/settings.local.json",
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"sh -c \'memo brief\'"}]}]}}\n')
    proj.run("install")
    check("a project whose own settings already inject the brief: no user-level SessionStart (it would show twice)",
        proj.ours("SessionStart") == nil and proj.ours("UserPromptSubmit") ~= nil)
    local pstatus = proj.run("status")
    check("… and status does not call that a missing hook", pstatus:find("[OK] Claude Code hooks", 1, true) ~= nil
        and pstatus:find("not wired", 1, true) == nil, pstatus)

    local bad = world()
    put(bad.settings, "{ not json")
    local bout, bcode = bad.run("install")
    check("a settings.json that is not JSON: install fails, the file is untouched",
        bcode ~= 0 and slurp(bad.settings) == "{ not json" and bout:find("not valid JSON", 1, true) ~= nil, bout)

    local tr = world()
    tr.run("install --with-transcripts --no-notes")
    local post = tr.hooks().PostToolUse
    check("--with-transcripts adds PreCompact and PostToolUse (matcher *)", tr.ours("PreCompact") ~= nil
        and post and post[1].matcher == "*" and tr.ours("PostToolUse") ~= nil
        and slurp(tr.data .. "/luamemo/hooks/claude/_save.sh") == slurp(REPO .. "/hooks/claude/_save.sh"))
end)

-- ---------------------------------------------------------------------------
section("status, and the hooks as installed", function()
    local w = world()
    w.run("install --no-notes")
    local st = w.run("status")
    check("status: hooks wired and the block current, both OK", st:find("[OK] Claude Code hooks", 1, true) ~= nil
        and st:find("[OK] CLAUDE.md", 1, true) ~= nil and st:find("WARN", 1, true) == nil, st)
    put(w.data .. "/luamemo/hooks/claude/user_prompt.sh", "#!/bin/sh\n# older\n")
    check("status: a copy older than the shipped script is stale", w.run("status"):find("older than the installed luamemo", 1, true) ~= nil)
    os.remove(w.data .. "/luamemo/hooks/claude/block_file_memory.sh")
    check("status: a copy that is gone is said", w.run("status"):find("its copy is gone", 1, true) ~= nil)
    w.run("install --no-notes")
    check("install brings the copies back to the shipped scripts", w.run("status"):find("WARN", 1, true) == nil)
    put(w.md, "# notes only\n")
    check("status: no luamemo block is a WARN", w.run("status"):find("no luamemo block", 1, true) ~= nil)

    -- the installed SessionStart hook, as Claude Code runs it: the settings' own command line, from a project with a .luamemorc
    local lw = world()
    lw.run("install --no-notes")
    put(lw.proj .. "/.luamemorc", ("# luamemo\nMEMO_DB=%q\nMEMO_SCOPE=%s\nMEMO_EMBEDDER=hash\n"):format(os.getenv("MEMO_DB"), lw.scope))
    H.trust_rc(lw.proj .. "/.luamemorc", lw.home .. "/.config/luamemo")
    local cmd = lw.ours("SessionStart")
    local function session(dir)
        return H.sh(("cd / && printf '%%s' %s | env -i HOME=%q PATH=%q CLAUDE_PROJECT_DIR=%q sh -c %s"):format(
            q(json.encode({ cwd = dir })), lw.home, lua_dir .. ":" .. H.sys_path(), dir, q(cmd)))
    end
    local out = session(lw.proj)
    local ctx = (((json.decode(out) or {}).hookSpecificOutput) or {}).additionalContext or ""
    check("the installed SessionStart command injects the project's brief", ctx:find("=== LUAMEMO ===", 1, true) ~= nil, out)
    local none = session(lw.dir)
    check("… and nothing in a directory without a .luamemorc", none == "", none)
end)

-- ---------------------------------------------------------------------------
section("uninstall", function()
    local w = world()
    put(w.settings, ORIGINAL); put(w.md, "# my notes\n")
    w.run("install --no-notes")
    local out, code = w.run("uninstall")
    check("uninstall exits 0 and says what it removed", code == 0 and out:find("hooks removed", 1, true) ~= nil
        and out:find("block removed", 1, true) ~= nil, out)
    check("our hooks are gone; the Bash hook, the Stop hook, model and theme stay",
        w.ours("SessionStart") == nil and w.ours("UserPromptSubmit") == nil and w.ours("PreToolUse") == nil
        and w.commands("Stop")[1] == "echo done" and table.concat(w.commands("PreToolUse"), "|") == "echo other-tool"
        and H.sh(("jq -c 'keys_unsorted' %q"):format(w.settings)) == '["model","hooks","theme"]')
    check("the block is gone, the user's text stays", slurp(w.md) == "# my notes\n", slurp(w.md))
    check("the copies are removed", not exists(w.data .. "/luamemo/hooks"))

    local solo = world()
    solo.run("install --no-notes"); solo.run("uninstall")
    check("a settings file that held only our hooks loses the hooks key; CLAUDE.md that held only our block is removed",
        next(solo.hooks()) == nil and not exists(solo.md), slurp(solo.settings))
end)

-- ---------------------------------------------------------------------------
section("import-notes: the project's Claude Code memory notes become luamemo memories", function()
    local luamemo = require("luamemo")
    assert(pcall(luamemo.setup, { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true }))
    local db = require("luamemo.db")
    local w = world()
    os.execute(("mkdir -p %q"):format(w.notes_dir()))
    local nd = w.notes_dir()
    put(nd .. "/feedback-sed.md", '---\nname: feedback-sed\ndescription: "Never edit files with sed \\"ever\\""\nmetadata:\n  node_type: memory\n  type: feedback\n---\n\nUse the Edit tool. **Why:** reviewable.\n')
    put(nd .. "/project-plan.md", "---\nname: project-plan\ndescription: Phase 3 is next\nmetadata:\n  type: project\n---\n\nShip the parser.\n")
    put(nd .. "/MEMORY.md", "# Memory Index\n- [a](feedback-sed.md)\n")
    local dry, dcode = w.run("import-notes --dry-run")
    check("--dry-run counts the notes and moves nothing", dcode == 0 and dry:find("2 note(s)", 1, true) ~= nil
        and H.sh(("ls %q | wc -l"):format(nd)) == "3", dry)
    local st = w.run("status")
    check("status names the notes still in files", st:find("2 Claude Code memory note(s) not in luamemo", 1, true) ~= nil, st)
    local out, code = w.run("import-notes")
    check("import-notes exits 0 and says 2 imported, 3 moved (the two notes and the old index)", code == 0
        and out:find("2 imported", 1, true) ~= nil and out:find("3 moved", 1, true) ~= nil, out)
    local rows = db.query("SELECT kind, title, body, tags, importance, metadata FROM lm_memories WHERE scope = ? ORDER BY kind", w.scope) or {}
    check("two memories: the feedback note a decision (importance 5), the project note a plan (3), once each",
        #rows == 2 and rows[1].kind == "decision" and tonumber(rows[1].importance) == 5 and rows[2].kind == "plan" and tonumber(rows[2].importance) == 3, #rows)
    check("… the title is the note's description (unescaped), the body holds it and the text, the source is recorded",
        rows[1] and rows[1].title == 'Never edit files with sed "ever"' and rows[1].body:find("Use the Edit tool.", 1, true) ~= nil
        and rows[1].metadata.source == "claude-memory-import" and rows[1].metadata.original_file == "feedback-sed.md"
        and json.encode(rows[1].tags):find("claude-memory", 1, true) ~= nil)
    local archive = nd .. "/../memory-archive-" .. os.date("%Y-%m-%d")
    check("the originals moved to memory-archive-DATE, the user's own index with them; MEMORY.md is a pointer to luamemo",
        H.sh(("ls %q"):format(nd)) == "MEMORY.md" and slurp(nd .. "/MEMORY.md"):find("lives in luamemo", 1, true) ~= nil
        and H.sh(("ls %q | wc -l"):format(archive)) == "3" and slurp(archive .. "/MEMORY.md"):find("[a](feedback-sed.md)", 1, true) ~= nil)
    local again = w.run("import-notes")
    check("run again: no notes, nothing imported twice", again:find("no Claude Code memory notes", 1, true) ~= nil
        and tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", w.scope)) == 2, again)

    -- a note luamemo cannot read stays, and nothing moves; once fixed, the one already imported is not written twice but is moved
    local w2 = world()
    os.execute(("mkdir -p %q"):format(w2.notes_dir()))
    put(w2.notes_dir() .. "/a.md", "---\nname: a\ndescription: Rule A\nmetadata:\n  type: feedback\n---\n\nbody a\n")
    put(w2.notes_dir() .. "/0-broken.md", "no frontmatter here\n")   -- (sorts first: a later good note must not hide it)
    w2.run("import-notes")
    check("a note without frontmatter cannot be imported: nothing is moved (the originals stay), the other is in luamemo",
        H.sh(("ls %q | sort | tr '\\n' ' '"):format(w2.notes_dir())) == "0-broken.md a.md"
        and tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", w2.scope)) == 1,
        H.sh(("ls %q | sort | tr '\\n' ' '"):format(w2.notes_dir())))
    os.remove(w2.notes_dir() .. "/0-broken.md")
    w2.run("import-notes")
    check("once fixed, the already-imported note is not written twice, and is moved",
        tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ?", w2.scope)) == 1 and H.sh(("ls %q"):format(w2.notes_dir())) == "MEMORY.md")
    db.run("DELETE FROM lm_memories WHERE scope IN (?, ?)", w.scope, w2.scope)

    -- a note whose text changed after its import updates that memory; both copies reach the archive under their own names
    local w3 = world()
    local n3 = w3.notes_dir()
    os.execute(("mkdir -p %q"):format(n3))
    local function rule(text) put(n3 .. "/feedback_t.md", "---\nname: feedback_t\ndescription: Rule T\nmetadata:\n  type: feedback\n---\n\n" .. text .. "\n") end
    rule("FIRST WORDING"); w3.run("import-notes")
    rule("SECOND WORDING"); local out3 = w3.run("import-notes")
    local rows3 = db.query("SELECT body FROM lm_memories WHERE scope = ?", w3.scope) or {}
    local arch3 = n3 .. "/../memory-archive-" .. os.date("%Y-%m-%d")
    check("a note changed after its import: the memory is updated (one memory, the new wording), and says so",
        #rows3 == 1 and rows3[1].body:find("SECOND WORDING", 1, true) ~= nil and rows3[1].body:find("FIRST WORDING", 1, true) == nil
        and out3:find("1 updated", 1, true) ~= nil, out3)
    check("… both versions of the file are in the archive: the first is not overwritten",
        slurp(arch3 .. "/feedback_t.md"):find("FIRST WORDING", 1, true) ~= nil and slurp(arch3 .. "/feedback_t.md.1"):find("SECOND WORDING", 1, true) ~= nil)

    -- no archive, no move: the notes and the index stay, the exit is not 0
    local w4 = world()
    local n4 = w4.notes_dir()
    os.execute(("mkdir -p %q"):format(n4))
    put(n4 .. "/a.md", "---\nname: a\ndescription: Rule A\nmetadata:\n  type: feedback\n---\n\nbody a\n")
    put(n4 .. "/MEMORY.md", "# mine\nhand written line\n")
    put(n4 .. "/../memory-archive-" .. os.date("%Y-%m-%d"), "a file where the archive directory should be")
    local out4, code4 = w4.run("import-notes")
    check("an archive that cannot be made: an error, the exit is not 0, the note and the user's index stay as they were",
        code4 ~= 0 and out4:find("could not make", 1, true) ~= nil and slurp(n4 .. "/MEMORY.md") == "# mine\nhand written line\n"
        and exists(n4 .. "/a.md"), out4)

    -- a flat `type:` line (not under metadata:) is read; a note that cannot be read is named
    local w5 = world()
    local n5 = w5.notes_dir()
    os.execute(("mkdir -p %q"):format(n5))
    put(n5 .. "/flat.md", "---\nname: flat\ndescription: A flat rule\ntype: feedback\n---\n\nbody\n")
    put(n5 .. "/0-bad.md", "no frontmatter\n")
    local out5 = w5.run("import-notes")
    local flat = db.first("SELECT kind, importance FROM lm_memories WHERE scope = ?", w5.scope)
    check("a flat type: line is read (decision, importance 5)", flat and flat.kind == "decision" and tonumber(flat.importance) == 5, flat and flat.kind)
    check("an unreadable note is named in the answer, and nothing is moved",
        out5:find("not readable as notes", 1, true) ~= nil and out5:find("0-bad.md", 1, true) ~= nil and exists(n5 .. "/flat.md"), out5)
    db.run("DELETE FROM lm_memories WHERE scope IN (?, ?, ?, ?)", w3.scope, w4.scope, w5.scope, w.scope)
end)

-- ---------------------------------------------------------------------------
section("what install and uninstall leave of the user's own files", function()
    -- CLAUDE.md: an unterminated begin marker is not a block, and uninstall touches only the block
    local w = world()
    put(w.md, "before\n<!-- luamemo:begin orphan -->\nUSER TEXT BETWEEN\n")
    w.run("install --no-notes"); w.run("install --no-notes")
    local md = slurp(w.md)
    check("a begin marker without an end: the user's text after it survives two installs, and there is one complete block",
        md:find("USER TEXT BETWEEN", 1, true) ~= nil and select(2, md:gsub("<!%-%- luamemo:end %-%->", "")) == 1, md)
    local w2 = world()
    local original = "# notes\n\n\n\nthree blank lines above stay\n\n```\ncode\n\n\n\nblank lines in a fence\n```"
    put(w2.md, original)
    w2.run("install --no-notes"); w2.run("uninstall")
    check("install then uninstall leaves the rest of CLAUDE.md as it was (blank-line runs, no trailing newline)",
        slurp(w2.md):gsub("\n$", "") == original, slurp(w2.md))
    check("the block is short (it is read in every session of every project)", #require("luamemo.cli.agent").CLAUDE_MD_BLOCK < 700)

    -- settings.json: a symlink stays a link, the mode stays, the backup keeps the mode; another tool's hook stays
    local w3 = world()
    os.execute(("mkdir -p %q"):format(w3.dir .. "/dot"))
    put(w3.dir .. "/dot/settings.json", '{"env":{"TOKEN":"x"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/opt/othertool/hooks/claude/user_prompt.sh"}]}]}}\n')
    os.execute(("chmod 600 %q && ln -s %q %q"):format(w3.dir .. "/dot/settings.json", w3.dir .. "/dot/settings.json", w3.settings))
    w3.run("install --no-notes")
    local function mode(f) return H.sh(("stat -c %%a %q 2>/dev/null || stat -f %%Lp %q"):format(f, f)) end
    check("a symlinked settings.json is written through: still a link, the target has the hooks, mode 600 kept",
        H.sh(("test -L %q && echo link"):format(w3.settings)) == "link" and slurp(w3.dir .. "/dot/settings.json"):find("luamemo-agent", 1, true) ~= nil
        and mode(w3.dir .. "/dot/settings.json") == "600", mode(w3.dir .. "/dot/settings.json"))
    check("… the backup of the original has the same mode (it holds the same secrets)", mode(w3.settings .. ".luamemo-bak") == "600",
        mode(w3.settings .. ".luamemo-bak"))
    check("… another tool's hook with a script of the same name is not luamemo's: it stays, install and uninstall",
        table.concat(w3.commands("UserPromptSubmit"), "|"):find("/opt/othertool/hooks/claude/user_prompt.sh", 1, true) ~= nil)
    w3.run("uninstall")
    check("… after uninstall too", table.concat(w3.commands("UserPromptSubmit"), "|") == "/opt/othertool/hooks/claude/user_prompt.sh")

    -- the transcript hooks: they stay wired on a later plain install, until --no-transcripts; status sees every copy
    local w4 = world()
    w4.run("install --with-transcripts --no-notes")
    w4.run("install --no-notes")
    check("a plain install after --with-transcripts keeps PreCompact and PostToolUse", w4.ours("PreCompact") ~= nil and w4.ours("PostToolUse") ~= nil)
    check("status lists them among the hooks", w4.run("status"):find("PreCompact", 1, true) ~= nil)
    os.remove(w4.data .. "/luamemo/hooks/claude/_project.sh")
    check("status: a missing _project.sh copy (every hook sources it) is a WARN", w4.run("status"):find("_project.sh (its copy is gone)", 1, true) ~= nil)
    w4.run("install --no-transcripts --no-notes")
    check("--no-transcripts takes them out (and the three others stay)", w4.ours("PreCompact") == nil and w4.ours("PostToolUse") == nil
        and w4.ours("UserPromptSubmit") ~= nil)
end)

-- ---------------------------------------------------------------------------
-- Delta round: what a plain install, an uninstall and a dry run do with entries that are not (or not only) luamemo's.
section("transcript hooks: whose they are decides whether they stay; uninstall and dry runs leave what is not ours", function()
    -- wired by hand as the README describes (a path through luamemo/hooks/claude, no marker): re-wired, not deleted
    local w = world()
    put(w.settings, '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"bash /home/u/code/luamemo/hooks/claude/pre_compact.sh"}]}],'
        .. '"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"bash /home/u/code/luamemo/hooks/claude/post_message.sh"}]}]}}\n')
    w.run("install --no-notes")
    check("transcript hooks wired by hand into luamemo's scripts are kept (in the installer's form), not deleted by a plain install",
        w.ours("PreCompact") ~= nil and w.ours("PostToolUse") ~= nil and not table.concat(w.commands("PreCompact"), "|"):find("/home/u/code", 1, true))
    -- another tool's pre_compact.sh is not luamemo's: it stays, and it does not switch the transcript capture on
    local w2 = world()
    put(w2.settings, '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"/home/u/.claude/hooks/pre_compact.sh"}]}]}}\n')
    w2.run("install --no-notes"); w2.run("install --no-notes")
    check("another tool's pre_compact.sh stays, and no transcript hook of luamemo's is added by a plain install",
        table.concat(w2.commands("PreCompact"), "|") == "/home/u/.claude/hooks/pre_compact.sh" and w2.ours("PostToolUse") == nil
        and w2.ours("PreCompact") == nil)

    -- uninstall: a settings.json without luamemo's hooks is not touched (no reformatting, no backup, no "removed")
    local w3 = world()
    local theirs = '{\n    "hooks": {\n        "Stop": [\n            {"hooks": [{"type": "command", "command": "echo done"}]}\n        ]\n    }\n}'
    put(w3.settings, theirs)
    local out3 = w3.run("uninstall")
    check("uninstall with none of luamemo's hooks in settings.json: byte-identical, no backup, says so",
        slurp(w3.settings) == theirs and not exists(w3.settings .. ".luamemo-bak") and out3:find("no luamemo hooks", 1, true) ~= nil, out3)
    -- uninstall: a symlinked CLAUDE.md that held only the block stays a link, its target is emptied
    local w4 = world()
    os.execute(("mkdir -p %q"):format(w4.dir .. "/dot"))
    put(w4.dir .. "/dot/CLAUDE.md", "")
    os.execute(("ln -s %q %q"):format(w4.dir .. "/dot/CLAUDE.md", w4.md))
    w4.run("install --no-notes")
    check("install wrote the block through the link", slurp(w4.dir .. "/dot/CLAUDE.md"):find("luamemo:begin", 1, true) ~= nil)
    w4.run("uninstall")
    check("uninstall keeps the symlinked CLAUDE.md a link and takes the block out of its target",
        H.sh(("test -L %q && echo link"):format(w4.md)) == "link" and slurp(w4.dir .. "/dot/CLAUDE.md"):find("luamemo:begin", 1, true) == nil)

    -- import-notes --dry-run names a note that is not readable as one (the real run will not move anything then)
    local w5 = world()
    os.execute(("mkdir -p %q"):format(w5.notes_dir()))
    put(w5.notes_dir() .. "/a.md", "---\nname: a\ndescription: d\nmetadata:\n  type: user\n---\nbody of a\n")
    put(w5.notes_dir() .. "/bad.md", "no frontmatter at all\n")
    local out5 = w5.run("import-notes --dry-run --dir " .. q(w5.notes_dir()))
    check("import-notes --dry-run names the unreadable note", out5:find("bad.md", 1, true) ~= nil and out5:find("1 to import", 1, true) ~= nil, out5)

    -- doctor sees an out-of-date copy of a hook script, as status does
    local w6 = world()
    w6.run("install --no-notes")
    local copy = w6.data .. "/luamemo/hooks/claude/user_prompt.sh"
    put(copy, slurp(copy) .. "\n# stale\n")
    -- (an installed luamemo, as a rock lays it out: bin/memo with mcp/ and hooks/ beside bin/ — no `cli/` in memo's own path,
    -- so doctor has to be told where the shipped hooks are, as `memo agent` is)
    local prefix = w6.dir .. "/prefix"
    os.execute(("mkdir -p %q && cp %q %q/memo && ln -s %q %q/mcp && ln -s %q %q/hooks"):format(prefix .. "/bin", MEMO, prefix .. "/bin",
        REPO .. "/mcp", prefix, REPO .. "/hooks", prefix))
    -- (LUA_PATH: luamemo's modules come from this checkout — a machine with no rock installed, like CI, has them nowhere else)
    local doctor = H.sh(("cd %q && env -i HOME=%q PATH=%q LUA_PATH=%q XDG_DATA_HOME=%q MEMO_DB=%q MEMO_SCOPE=%s MEMO_EMBEDDER=hash MEMO_PROJECT=%q bash %q doctor </dev/null")
        :format(w6.proj, w6.home, lua_dir .. ":" .. H.sys_path(), REPO .. "/?.lua;" .. REPO .. "/?/init.lua;;", w6.data, os.getenv("MEMO_DB"), w6.scope, w6.proj, prefix .. "/bin/memo"))
    check("memo doctor (an installed layout) warns about a hook copy older than the installed luamemo",
        doctor:find("Claude Code hooks out of date", 1, true) ~= nil and doctor:find("user_prompt.sh", 1, true) ~= nil, doctor)
end)

-- ---------------------------------------------------------------------------
-- calibrate's Claude Code phase (cli/memo _calibrate_agent_phase): it runs, --no-agent skips it, --dry-run writes nothing
section("calibrate: the Claude Code phase", function()
    local function calibrate(w, flags)
        return H.sh(("cd %q && env -i HOME=%q PATH=%q XDG_DATA_HOME=%q MEMO_EMBEDDER=hash MEMO_PROJECT= bash %q calibrate --no-mcp --no-plugin "
            .. "--no-git --no-comments --allow-hash %s </dev/null 2>&1"):format(w.proj, w.home, lua_dir .. ":" .. H.sys_path(), w.data, MEMO, flags or ""))
    end
    local function claude_listing(w) return H.sh(("ls -A %q"):format(w.claude)) end
    local w = world()
    local out = calibrate(w)
    check("calibrate wires the hooks and the CLAUDE.md block without asking", w.ours("UserPromptSubmit") ~= nil and w.ours("PreToolUse") ~= nil
        and slurp(w.md):find("luamemo:begin", 1, true) ~= nil, out:sub(-600))
    local w2 = world()
    local out2 = calibrate(w2, "--no-agent")
    check("calibrate --no-agent leaves ~/.claude untouched", claude_listing(w2) == "", claude_listing(w2) .. "\n" .. out2:sub(-400))
    local w3 = world()
    local out3 = calibrate(w3, "--dry-run")
    check("calibrate --dry-run writes nothing into ~/.claude", claude_listing(w3) == "", claude_listing(w3) .. "\n" .. out3:sub(-400))
end)

-- ---------------------------------------------------------------------------
section("calibrate and doctor know about it", function()
    local w = world()
    local help = H.sh(("env -i HOME=%q PATH=%q bash %q calibrate --help"):format(w.home, H.sys_path(), MEMO))
    check("memo calibrate --help lists --no-agent", help:find("--no-agent", 1, true) ~= nil, help)
    local agent_help = w.run("--help")
    check("memo agent --help lists install, uninstall, status and import-notes", agent_help:find("install", 1, true) ~= nil
        and agent_help:find("uninstall", 1, true) ~= nil and agent_help:find("import-notes", 1, true) ~= nil, agent_help)
    local doctor = H.sh(("cd %q && env -i HOME=%q PATH=%q XDG_DATA_HOME=%q MEMO_DB=%q MEMO_SCOPE=%s MEMO_EMBEDDER=hash MEMO_PROJECT=%q bash %q doctor </dev/null")
        :format(w.proj, w.home, lua_dir .. ":" .. H.sys_path(), w.data, os.getenv("MEMO_DB"), w.scope, w.proj, MEMO))
    check("memo doctor reports the Claude Code integration (hooks not wired yet)", doctor:find("Claude Code hooks not wired", 1, true) ~= nil, doctor)
end)

os.execute(("rm -rf %q"):format(base))
finish()
