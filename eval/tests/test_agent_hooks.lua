-- eval/tests/test_agent_hooks.lua
-- Phase 23.2 — the Claude Code hooks that make luamemo the agent's memory without the agent
-- having to remember to: user_prompt.sh (UserPromptSubmit → memo sense, in the background) and
-- block_file_memory.sh (PreToolUse → no file memory in a project that uses luamemo), both run
-- the way Claude Code runs them (JSON on stdin), and the plugin's hooks.json that wires them.
-- Run: luajit eval/tests/run.lua --only agent_hooks

package.path = "./?.lua;./?/init.lua;" .. package.path
local H = require("eval.tests._harness")
local T = H.new("Agent hooks")
local check, section, finish = T.check, T.section, T.finish
local json = require("luamemo.json")
local q = require("luamemo.util").shell_quote

local REPO = (H.sh("pwd"))
local BLOCK, PROMPT = REPO .. "/hooks/claude/block_file_memory.sh", REPO .. "/hooks/claude/user_prompt.sh"
local base = os.tmpname(); os.remove(base)
os.execute(("mkdir -p %q"):format(base))
local function path(...) return base .. "/" .. table.concat({ ... }, "/") end
local put = H.write_file

-- ---------------------------------------------------------------------------
section("block_file_memory.sh: no file memory in a project that uses luamemo", function()
    local with_rc, without_rc, home = path("withrc"), path("norc"), path("home")
    os.execute(("mkdir -p %q %q %q %q"):format(with_rc .. "/a/b", without_rc, home .. "/proj", home .. "/.config"))
    put(with_rc .. "/.luamemorc", "# luamemo\n")
    put(home .. "/.luamemorc", "# the user's own\n")
    local MEM = "/root/.claude/projects/-some-project/memory/note.md"
    local function run(input, extra_env)
        return H.sh(("printf '%%s' %s | env -i HOME=%q PATH=%q %s sh %q"):format(q(json.encode(input)), home,
            H.sys_path(), extra_env or "", BLOCK))
    end
    local function decision(out) return (((json.decode(out) or {}).hookSpecificOutput) or {}).permissionDecision end
    local out, code = run({ tool_name = "Write", cwd = with_rc, tool_input = { file_path = MEM } })
    check("a write under .claude/projects/*/memory/ in a project with a .luamemorc: denied, with the luamemo tools named",
        code == 0 and decision(out) == "deny" and out:find("memory_write", 1, true) ~= nil and out:find("memory_sense", 1, true) ~= nil, out)
    check("… from a subdirectory of the project too", decision((run({ cwd = with_rc .. "/a/b", tool_input = { file_path = MEM } }))) == "deny")
    check("… and an edit of a notebook there", decision((run({ cwd = with_rc, tool_input = { notebook_path = MEM } }))) == "deny")
    check("… the project is CLAUDE_PROJECT_DIR when Claude Code names it",
        decision((run({ cwd = without_rc, tool_input = { file_path = MEM } }, "CLAUDE_PROJECT_DIR=" .. q(with_rc)))) == "deny")
    local silent, scode = run({ cwd = without_rc, tool_input = { file_path = MEM } })
    check("a project without a .luamemorc keeps Claude Code's own memory: allowed, nothing printed", scode == 0 and silent == "", silent)
    local s2, c2 = run({ cwd = home .. "/proj", tool_input = { file_path = MEM } })
    check("the user's own ~/.luamemorc does not make every project a luamemo project", c2 == 0 and s2 == "", s2)
    local s3, c3 = run({ cwd = with_rc, tool_input = { file_path = with_rc .. "/src/x.lua" } })
    check("any other file is allowed, nothing printed", c3 == 0 and s3 == "", s3)
    local s4, c4 = run({ cwd = with_rc, tool_input = { file_path = "/root/.claude/projects/-p/memory-archive/a.md" } })
    check("a directory that only starts with 'memory' is not the memory directory", c4 == 0 and s4 == "", s4)
    local s5, c5 = H.sh(("printf 'not json' | env -i HOME=%q PATH=%q sh %q"):format(home, H.sys_path(), BLOCK))
    check("input that is no JSON: allowed, exit 0", c5 == 0 and s5 == "", s5)
end)

-- ---------------------------------------------------------------------------
section("user_prompt.sh: what the user says reaches memory, in the background", function()
    local luamemo = require("luamemo")
    assert(pcall(luamemo.setup, { embedder_local = "hash", embed_dim = 384, skip_embed_probe = true }))
    local db = require("luamemo.db")
    local SCOPE = "repo:agenthooks"
    local proj, home, bare = path("prompt-proj"), path("prompt-home"), path("prompt-bare")
    os.execute(("mkdir -p %q %q %q"):format(proj, home .. "/.config/luamemo", bare))
    put(proj .. "/.luamemorc", ("# luamemo\nMEMO_DB=%q\nMEMO_SCOPE=%s\nMEMO_EMBEDDER=hash\n"):format(os.getenv("MEMO_DB"), SCOPE))
    H.trust_rc(proj .. "/.luamemorc", home .. "/.config/luamemo")
    local transcript = path("transcript.jsonl")
    local w = assert(io.open(transcript, "w"))
    w:write(json.encode({ type = "user", message = { role = "user", content = "Fix the cache." } }), "\n")
    w:write(json.encode({ type = "assistant", message = { role = "assistant", content = {
        { type = "text", text = "I rewrote cache.lua with sed -i." }, { type = "tool_use", id = "t1", name = "Bash", input = {} } } } }), "\n")
    w:close()
    local lua_dir = H.lua_dir()
    local function hook(prompt, dir)
        local input = json.encode({ session_id = "s1", transcript_path = transcript, cwd = dir or proj, prompt = prompt })
        local t0 = os.time()
        local out, code = H.sh(("cd %q && printf '%%s' %s | env -i HOME=%q PATH=%q MEMO_LUA=%q CLAUDE_PROJECT_DIR=%q bash %q"):format(
            dir or proj, q(input), home, lua_dir .. ":" .. H.sys_path(), H.lua_bin(), dir or proj, PROMPT))
        return out, code, os.time() - t0
    end
    local function rules() return tonumber(db.value("SELECT count(*) FROM lm_memories WHERE scope = ? AND kind = 'decision'", SCOPE)) or 0 end
    local function wait_for(n)
        for _ = 1, 100 do
            if rules() >= n then return true end
            os.execute("sleep 0.2")
        end
        return false
    end
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)

    -- the prompts that are no signal: a question, a slash command, a tiny one
    for _, p in ipairs({ "How do I run the tests?", "/clear everything and start over", "ok" }) do
        local out, code = hook(p)
        check("a prompt that says no rule (" .. p:sub(1, 20) .. "…): exit 0, nothing printed", code == 0 and out == "", out)
    end
    local out, code, secs = hook("Never edit repository files with sed, always use the Edit tool.")
    check("a rule: the hook returns at once with nothing printed (the work is in the background)", code == 0 and out == "" and secs <= 2,
        ("code=%s secs=%s out=%s"):format(tostring(code), tostring(secs), out))
    check("… and the rule becomes a decision memory of the project's scope", wait_for(1))
    os.execute("sleep 2")
    local rows = db.query("SELECT title, body, tags FROM lm_memories WHERE scope = ? AND kind = 'decision'", SCOPE) or {}
    check("… exactly one (the prompts that say no rule stored nothing)", #rows == 1, #rows)
    check("… it holds the user's words and what the assistant had just said (read from the transcript)",
        rows[1] and rows[1].title:find("^Never edit repository files with sed") ~= nil
        and rows[1].body:find("The assistant had just said: I rewrote cache.lua with sed -i.", 1, true) ~= nil, rows[1] and rows[1].body)

    local out2, code2 = hook("Never edit repository files with sed, always use the Edit tool.")
    os.execute("sleep 3")
    check("the same prompt again stores nothing more", code2 == 0 and out2 == "" and rules() == 1, rules())

    -- no luamemo in the project: nothing to find, nothing printed, nothing stored anywhere we can see
    local out3, code3 = hook("From now on, answer in Portuguese.", bare)
    os.execute("sleep 2")
    check("a directory without a .luamemorc: exit 0, nothing printed, nothing stored", code3 == 0 and out3 == "" and rules() == 1, rules())
    db.run("DELETE FROM lm_memories WHERE scope = ?", SCOPE)
end)

-- ---------------------------------------------------------------------------
section("the hooks' calls to memo, observed (a stub memo records them)", function()
    local proj, home, bare, copies = path("obs-proj"), path("obs-home"), path("obs-bare"), path("obs-copies")
    os.execute(("mkdir -p %q %q %q %q"):format(proj, home, bare, copies))
    put(proj .. "/.luamemorc", "# luamemo\n")
    local stub, log = path("obs-memo"), path("obs-memo.log")
    put(stub, '#!/bin/sh\n{ echo "ARGS: $*"; echo "SKIP_PROBE: ${MEMO_SKIP_EMBED_PROBE:-}"; echo "STDIN: $(cat)"; echo "---"; } >> "$MEMO_STUB_LOG"\n'
        .. '[ "$1" = brief ] && printf "=== LUAMEMO ===\\nstub brief\\n=== END ==="\nexit 0\n')
    os.execute(("chmod +x %q && cp %q/*.sh %q/"):format(stub, REPO .. "/hooks/claude", copies))   -- (copies: no cli/memo beside them)
    local transcript = path("obs-transcript.jsonl")
    put(transcript, json.encode({ type = "assistant", message = { role = "assistant", content = { { type = "text", text = "I used sed -i." } } } }) .. "\n")
    local function env(extra) return ("env -i HOME=%q PATH=%q MEMO_STUB_LOG=%q MEMO_BIN=%q %s"):format(home, "/usr/bin:/bin", log, stub, extra or "") end
    local function calls() local t = H.slurp(log) or ""; return select(2, t:gsub("%-%-%-\n", "")), t end
    local function wait_calls(n) for _ = 1, 100 do if (calls()) >= n then return true end; os.execute("sleep 0.1") end end

    os.remove(log)
    for _, p in ipairs({ "/clear everything now", "ok", "" }) do
        H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ prompt = p, transcript_path = transcript, cwd = proj })), env(), copies .. "/user_prompt.sh"))
    end
    H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ prompt = "Never edit files with sed, ever.", transcript_path = transcript, cwd = bare })),
        env(), copies .. "/user_prompt.sh"))
    H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ prompt = "Never edit files with sed, ever.", transcript_path = transcript, cwd = proj })),
        env(), copies .. "/user_prompt.sh"))
    check("the prompt hook calls memo once: not for a slash command, a tiny prompt, an empty one, or a directory without a .luamemorc", wait_calls(1))
    os.execute("sleep 0.5")
    local n, text = calls()
    check("… exactly once, as `memo sense`, with the embedder probe off, the assistant's words and the prompt on stdin",
        n == 1 and text:find("ARGS: sense\n", 1, true) ~= nil and text:find("SKIP_PROBE: true", 1, true) ~= nil
        and text:find("I used sed -i.", 1, true) ~= nil and text:find("Never edit files with sed, ever.", 1, true) ~= nil, text)

    os.remove(log)
    local out = H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ cwd = proj })), env(), copies .. "/session_start.sh"))
    local ctx = ((((json.decode(out) or {}).hookSpecificOutput) or {}).additionalContext) or ""
    local n2, text2 = calls()
    check("session_start.sh: the brief wrapped as additionalContext, memo called as `brief` with the embedder probe off",
        ctx:find("stub brief", 1, true) ~= nil and n2 == 1 and text2:find("ARGS: brief\n", 1, true) ~= nil and text2:find("SKIP_PROBE: true", 1, true) ~= nil, out)
    os.remove(log)
    local none = H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ cwd = bare })), env(), copies .. "/session_start.sh"))
    local plugin = H.sh(("printf '%%s' %s | %s bash %q"):format(q(json.encode({ cwd = bare })), env("LUAMEMO_ANY_PROJECT=1"), copies .. "/session_start.sh"))
    check("… nothing in a directory without a .luamemorc, unless the plugin asks (LUAMEMO_ANY_PROJECT)",
        none == "" and plugin:find("stub brief", 1, true) ~= nil, none .. "|" .. plugin)

    -- the transcript hooks use the memo the installer pinned, though no memo is on PATH
    os.remove(log)
    H.sh(("printf '%%s' %s | %s MEMO_SCOPE=repo:obs bash %q"):format(q(json.encode({ session_id = "s1", transcript_path = transcript })), env(),
        copies .. "/pre_compact.sh"))
    local n3, text3 = calls()
    check("pre_compact.sh: saves through the pinned MEMO_BIN (memo is not on PATH)", n3 == 1 and text3:find("ARGS: write --scope repo:obs", 1, true) ~= nil
        and text3:find("ASSISTANT: I used sed -i.", 1, true) ~= nil, text3)

    -- the guard: a Claude Code config directory elsewhere; a project file that is a link to ~/.luamemorc is not a project
    local cfg = path("obs-cfg")
    local function deny(file, cwd, extra)
        local o = H.sh(("printf '%%s' %s | env -i HOME=%q PATH=%q %s sh %q"):format(q(json.encode({ cwd = cwd, tool_input = { file_path = file } })),
            home, H.sys_path(), extra or "", copies .. "/block_file_memory.sh"))
        return (((json.decode(o) or {}).hookSpecificOutput) or {}).permissionDecision == "deny"
    end
    check("the guard also denies $CLAUDE_CONFIG_DIR/projects/*/memory/*, and only with that variable set",
        deny(cfg .. "/projects/-p/memory/n.md", proj, "CLAUDE_CONFIG_DIR=" .. q(cfg)) and not deny(cfg .. "/projects/-p/memory/n.md", proj)
        and not deny(cfg .. "/projects/-p/notes/n.md", proj, "CLAUDE_CONFIG_DIR=" .. q(cfg)))
    put(home .. "/.luamemorc", "# the user's own\n")
    local linked = path("obs-linked"); os.execute(("mkdir -p %q && ln -s %q %q/.luamemorc"):format(linked, home .. "/.luamemorc", linked))
    check("a project's .luamemorc that is a link to ~/.luamemorc does not make it a luamemo project (memo's own rule)",
        not deny("/root/.claude/projects/-p/memory/n.md", linked) and deny("/root/.claude/projects/-p/memory/n.md", proj))
    check("a write with no 'memory' in it is allowed without jq even being there",
        H.sh(("printf '%%s' %s | env -i HOME=%q PATH=/nonexistent /bin/sh %q"):format(q(json.encode({ cwd = proj, tool_input = { file_path = "/x/a.lua" } })),
            home, copies .. "/block_file_memory.sh")) == "")
end)

-- ---------------------------------------------------------------------------
section("the plugin's hooks.json wires both", function()
    local hooks = (json.decode(H.slurp(REPO .. "/hooks/hooks.json") or "{}") or {}).hooks or {}
    local function command(event) return (((hooks[event] or {})[1] or {}).hooks or {})[1] end
    local up, pre = command("UserPromptSubmit"), command("PreToolUse")
    check("UserPromptSubmit runs hooks/claude/user_prompt.sh through bash", up and up.type == "command"
        and up.command:find("hooks/claude/user_prompt.sh", 1, true) ~= nil and up.command:find("^bash ") ~= nil)
    check("PreToolUse (Write|Edit|NotebookEdit) runs hooks/claude/block_file_memory.sh through bash",
        pre and hooks.PreToolUse[1].matcher == "Write|Edit|NotebookEdit" and pre.command:find("hooks/claude/block_file_memory.sh", 1, true) ~= nil
        and pre.command:find("^bash ") ~= nil)
    check("both have a short timeout (the session never waits on them)", up and pre and (up.timeout or 99) <= 10 and (pre.timeout or 99) <= 10)
    -- SessionStart is the installer's script too, told it is the plugin's (a project without a .luamemorc gets the brief)
    local ss = command("SessionStart")
    check("SessionStart runs hooks/claude/session_start.sh through bash with LUAMEMO_ANY_PROJECT=1", ss and ss.type == "command"
        and ss.command:find("^LUAMEMO_ANY_PROJECT=1 bash ") ~= nil and ss.command:find("hooks/claude/session_start.sh", 1, true) ~= nil, ss and ss.command)
    local bare = path("plugin-bare"); os.execute(("mkdir -p %q"):format(bare))
    local stub = path("plugin-stub-memo"); put(stub, "#!/bin/sh\necho 'plugin stub brief'\n"); os.execute(("chmod 755 %q"):format(stub))
    local sout = H.sh(("printf '%%s' %s | env -i HOME=%q PATH=%q CLAUDE_PLUGIN_ROOT=%q MEMO_BIN=%q sh -c %s"):format(q(json.encode({ cwd = bare })),
        path("home"), H.sys_path(), REPO, stub, q(ss and ss.command or "true")))
    check("the plugin's SessionStart command line injects the brief in a directory without a .luamemorc",
        sout:find("plugin stub brief", 1, true) ~= nil, sout)
    -- run the plugin's own command line, as Claude Code does
    local proj = path("plugin-proj"); os.execute(("mkdir -p %q"):format(proj)); put(proj .. "/.luamemorc", "# x\n")
    local input = json.encode({ cwd = proj, tool_input = { file_path = "/root/.claude/projects/-p/memory/n.md" } })
    local out = H.sh(("printf '%%s' %s | env -i HOME=%q PATH=%q CLAUDE_PLUGIN_ROOT=%q sh -c %s"):format(q(input), path("home"), H.sys_path(), REPO,
        q(pre and pre.command or "true")))
    check("the plugin's PreToolUse command line denies a memory-file write in a project with a .luamemorc",
        ((((json.decode(out) or {}).hookSpecificOutput) or {}).permissionDecision) == "deny", out)
end)

os.execute(("rm -rf %q"):format(base))
finish()
