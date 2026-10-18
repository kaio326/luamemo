-- luamemo.cli.probe
--
-- Host environment probes used by `memo calibrate` and `memo doctor`. Pure
-- shell-out, no external deps. Each probe returns { ok = bool, value = ?, err = ? }.

local M = {}

-- Every value a command line carries is quoted: a project directory named x$(…)y ran
-- its command in the project scan, one with a space scanned nothing.
local shq = require("luamemo.util").shell_quote

local function read_cmd(cmd)
    local f = io.popen(cmd .. " 2>/dev/null")
    if not f then return nil end
    local out = f:read("*a")
    local ok = f:close()
    if not ok or not out then return nil end
    return (out:gsub("%s+$", ""))
end

function M.has_command(name)
    local out = read_cmd("command -v " .. name)
    return out ~= nil and out ~= ""
end

function M.gpu()
    if not M.has_command("nvidia-smi") then
        return { ok = false, err = "nvidia-smi not found" }
    end
    local out = read_cmd("nvidia-smi --query-gpu=name,memory.free --format=csv,noheader,nounits")
    if not out or out == "" then
        return { ok = false, err = "nvidia-smi returned no data" }
    end
    -- "GeForce GTX 1080, 7600"
    local name, free_mb = out:match("^([^,]+),%s*(%d+)")
    return { ok = true, value = { name = name, free_mb = tonumber(free_mb) } }
end

function M.docker()
    if not M.has_command("docker") then
        return { ok = false, err = "docker not found" }
    end
    local out = read_cmd("docker info --format '{{.ServerVersion}}'")
    if not out or out == "" then
        return { ok = false, err = "docker daemon not reachable" }
    end
    return { ok = true, value = out }
end

function M.ollama(url)
    url = url or "http://localhost:11434"
    if not M.has_command("curl") then
        return { ok = false, err = "curl not found" }
    end
    local out = read_cmd("curl -fsS --max-time 2 " .. shq(url .. "/api/version"))
    if not out or out == "" then
        return { ok = false, err = "no response from " .. url }
    end
    return { ok = true, value = url }
end

-- embed_ready: can an HTTP embedder config embed RIGHT NOW? Runs one real
-- embedding through the production path (luamemo.embed → the adapter's
-- build_request / parse_response) — reachability alone is not proof the model
-- is pulled / loaded / answering in the adapter's shape.
-- Configures luamemo.embed with `cand`; calibrate's probe mode runs in its own
-- process, so nothing else is using that state.
-- cand: { embedder_adapter, embedder_url (full endpoint), embedder_model? }
-- Returns { ready = bool, dim = n?, reason = str? }.
function M.embed_ready(cand)
    local embed = require("luamemo.embed")
    local ok, cerr = pcall(embed.configure, {
        embedder_adapter = cand.embedder_adapter,
        embedder_url     = cand.embedder_url,
        embedder_model   = cand.embedder_model,
        embed_timeout_ms = cand.timeout_ms or 20000,   -- first call may load the model
    })
    if not ok then return { ready = false, reason = tostring(cerr) } end
    local pok, dim, err = pcall(embed.probe)
    if not pok then return { ready = false, reason = tostring(dim) } end
    if not dim then return { ready = false, reason = tostring(err) } end
    return { ready = true, dim = dim }
end

-- ollama_ready: the reachable Ollama at `base` (from ollama()) serves `model`
-- for embeddings. Returns { ready, url (full endpoint, host-side), model, dim, reason }.
function M.ollama_ready(base, model)
    model = model or "nomic-embed-text"
    local url = base:gsub("/+$", "") .. "/api/embeddings"
    local r = M.embed_ready({ embedder_adapter = "ollama", embedder_url = url, embedder_model = model })
    r.url, r.model = url, model
    if not r.ready then
        r.reason = r.reason .. " (is the model pulled? `ollama pull " .. model .. "`)"
    end
    return r
end

-- parse_docker_port: host address for a container's published port from a
-- `docker ps` Ports column ("127.0.0.1:8081->80/tcp", "0.0.0.0:8081->80/tcp,
-- [::]:8081->80/tcp"). Wildcard binds map to 127.0.0.1. nil when unpublished.
function M.parse_docker_port(ports, container_port)
    container_port = tostring(container_port or 80)
    for ip, hp in (ports or ""):gmatch("([%d%.]+):(%d+)%->" .. container_port .. "/tcp") do
        return (ip == "0.0.0.0" and "127.0.0.1" or ip) .. ":" .. hp
    end
    return nil
end

-- tei_ready: the first RUNNING TEI sidecar (a docker container from the
-- text-embeddings-inference image with a published port) that answers a real
-- embedding. Returns { ready, url (host-side /embed endpoint), model, dim,
-- container, reason }; model comes from TEI's /info.
function M.tei_ready()
    if not M.has_command("docker") then return { ready = false, reason = "docker not found" } end
    local out = read_cmd("docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'")
    local reason = "no running text-embeddings-inference container"
    for line in (out or ""):gmatch("[^\n]+") do
        local name, image, ports = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
        if image and image:find("text%-embeddings%-inference", 1, false) then
            local hostport = M.parse_docker_port(ports, 80)
            if not hostport then
                reason = "TEI container " .. name .. " has no published port"
            else
                local base = "http://" .. hostport
                local model
                local http = require("luamemo.http")
                local st, body = http.request(base .. "/info", { method = "GET", timeout_ms = 3000 })
                if st == 200 and body then
                    local info = require("luamemo.json").decode(body)
                    model = type(info) == "table" and info.model_id or nil
                end
                local r = M.embed_ready({ embedder_adapter = "tei", embedder_url = base .. "/embed" })
                if r.ready then
                    r.url, r.model, r.container = base .. "/embed", model or "unknown", name
                    return r
                end
                reason = "TEI container " .. name .. " at " .. base .. ": " .. tostring(r.reason)
            end
        end
    end
    return { ready = false, reason = reason }
end

function M.ram_mb()
    -- Linux: /proc/meminfo MemAvailable
    local f = io.open("/proc/meminfo", "r")
    if not f then return { ok = false, err = "/proc/meminfo not readable" } end
    local meminfo = f:read("*a"); f:close()
    local kb = meminfo:match("MemAvailable:%s*(%d+)")
    if not kb then return { ok = false, err = "MemAvailable not found" } end
    return { ok = true, value = math.floor(tonumber(kb) / 1024) }
end

-- Project scan: file extension census + multilingual hint.
function M.scan_project(root)
    root = root or "."
    local out = read_cmd(string.format(
        "find %s -type f -not -path '*/node_modules/*' -not -path '*/.git/*' " ..
        "-not -path '*/.venv/*' -not -path '*/__pycache__/*' 2>/dev/null " ..
        -- (POSIX: \+ is GNU sed's; macOS's found no extension at all)
        "| sed -n 's/.*\\.\\([A-Za-z0-9][A-Za-z0-9]*\\)$/\\1/p' | sort | uniq -c | sort -rn | head -20",
        shq(root)))
    local ext_census = {}
    if out then
        for line in out:gmatch("[^\n]+") do
            local count, ext = line:match("^%s*(%d+)%s+(.+)$")
            if count and ext then
                table.insert(ext_census, { ext = ext, count = tonumber(count) })
            end
        end
    end
    -- Multilingual hint: presence of locales/ui_*.lua, i18n/, lang directories.
    local mlines = read_cmd(string.format(
        "find %s -type d \\( -name 'locales' -o -name 'i18n' -o -name 'lang' -o -name 'translations' \\) " ..
        "-not -path '*/node_modules/*' 2>/dev/null | head -3", shq(root))) or ""
    local multilingual_hint = mlines ~= ""
    return { ext_census = ext_census, multilingual_hint = multilingual_hint }
end

-- gguf: can this host run the in-process GGUF embedder (luamemo.embedders.gguf_ffi)?
-- Needs LuaJIT (FFI) at runtime, plus a C toolchain + cmake to build the shim
-- (and llama.cpp, if not already built). Reports which pieces are missing so the
-- guide can tell the user exactly what to install.
--- Can the in-process GGUF embedder run here? LuaJIT, and a shim — already there (built,
--- or installed by `memo gguf install`), prebuilt for this machine in this release, or
--- buildable (a C toolchain, cmake, git). `prebuilt`: the bundle `memo gguf install` gets.
function M.gguf()
    local have_luajit = M.has_command("luajit")
    local have_cc     = M.has_command("cc") or M.has_command("gcc")
    local have_cmake  = M.has_command("cmake")
    local have_git    = M.has_command("git")
    local shim_mod    = require("luamemo.embedders.native.ffi_shim")
    local have_shim   = shim_mod.exists(shim_mod.shim_path())
    local prebuilt    = (not have_shim) and require("luamemo.embedders.native.bundle").available() or nil
    local buildable   = have_cc and have_cmake and have_git
    local missing = {}
    if not have_luajit then missing[#missing + 1] = "luajit" end
    if not (have_shim or prebuilt or buildable) then
        if not have_cc     then missing[#missing + 1] = "cc/gcc" end
        if not have_cmake  then missing[#missing + 1] = "cmake" end
        if not have_git    then missing[#missing + 1] = "git" end
    end
    return {
        ok      = have_luajit and (have_shim or prebuilt ~= nil or buildable),
        luajit  = have_luajit, cc = have_cc, cmake = have_cmake, git = have_git,
        shim    = have_shim, prebuilt = prebuilt,
        missing = missing,
    }
end

-- The model the gguf setup guide downloads (step 2).
M.GGUF_DEFAULT_MODEL = "embeddinggemma-300M-Q8_0.gguf"

local file_exists = require("luamemo.util").exists

-- Where a gguf embedding model already sits: MEMO_GGUF_MODEL / MEMO_GEMMA_MODEL /
-- MEMO_EMBEDDER_MODEL when they name an existing file, else the guide's default
-- download path (~/models/<GGUF_DEFAULT_MODEL>). nil when none exists.
function M.gguf_model_path()
    for _, var in ipairs({ "MEMO_GGUF_MODEL", "MEMO_GEMMA_MODEL", "MEMO_EMBEDDER_MODEL" }) do
        local v = os.getenv(var)
        if file_exists(v) then return v end
    end
    local home = os.getenv("HOME")
    local p = home and (home .. "/models/" .. M.GGUF_DEFAULT_MODEL)
    if file_exists(p) then return p end
    return nil
end

-- Directory holding the luamemo/ module tree this file was loaded from, so a
-- luajit subprocess resolves the same modules (and the same gguf_shim.so).
local function module_root()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)[/\\]luamemo[/\\]cli[/\\]probe%.lua$")
        or (src:match("^luamemo[/\\]cli[/\\]probe%.lua$") and ".")
end

-- gguf_ready: can the in-process embedder run RIGHT NOW? Stronger than gguf().ok
-- (which only says it could be built): the shim must be built, a model file
-- present, and one real embedding must succeed under luajit — files existing is
-- not proof that libllama loads. Loads the model once (~1-2 s); call only when
-- gguf().ok. Returns { ready = bool, model = path?, dim = n?, reason = str? }.
function M.gguf_ready()
    local shim = require("luamemo.embedders.native.ffi_shim")
    if not shim.exists(shim.shim_path()) then
        return { ready = false, reason = "native shim not built" }
    end
    local model = M.gguf_model_path()
    if not model then
        return { ready = false, reason = "no GGUF model found (MEMO_GGUF_MODEL or ~/models/"
            .. M.GGUF_DEFAULT_MODEL .. ")" }
    end
    local root = module_root()
    if not root then return { ready = false, reason = "cannot locate the luamemo module tree" } end
    local code = 'local e = require("luamemo.embedders.gguf_ffi") '
        .. 'local ok, err = e.selftest({}) '
        .. 'io.write(ok and ("OK " .. tostring(e.dim({}))) or ("ERR " .. tostring(err)))'
    -- This process's module paths (memo keeps only absolute entries), not ";;": the
    -- defaults would put the working directory (./?.lua) back in front.
    local out = read_cmd(("MEMO_GGUF_MODEL=%s LUA_PATH=%s LUA_CPATH=%s luajit -e %s"):format(
        shq(model), shq(root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path),
        shq(package.cpath), shq(code)))
    local dim = out and out:match("^OK (%d+)$")
    if dim then return { ready = true, model = model, dim = tonumber(dim) } end
    return { ready = false, model = model,
             reason = "selftest failed: " .. ((out and out:gsub("^ERR ", "")) or "luajit did not run") }
end

-- generative: recommend the in-process generative model for sensing "dreams"
-- extraction (luamemo.sensing.generate). It runs on the SAME runtime as the gguf
-- embedder. With a GPU that has enough free VRAM we recommend the 4B instruct
-- model on GPU — it labels/extracts far more reliably than the 1B model, which
-- is precision-first but weak at open extraction. Otherwise the 1B model on CPU,
-- the zero-dependency floor. NOTE: GPU offload (n_gpu != 0) additionally requires
-- a CUDA-built libllama; we surface that as a prerequisite rather than probe it.
local VRAM_MB_FOR_4B = 3800   -- gemma-3-4b Q4_K_M weights (~2.6GB) + context/KV headroom

function M.generative()
    local g = M.gguf()
    if not g.ok then
        return { ok = false, err = "generative sensing needs the gguf runtime (LuaJIT + toolchain)",
                 missing = g.missing }
    end
    local gpu = M.gpu()
    if gpu.ok and gpu.value and (tonumber(gpu.value.free_mb) or 0) >= VRAM_MB_FOR_4B then
        return {
            ok = true, device = "gpu", model = "gemma-3-4b-it", quant = "Q4_K_M", n_gpu = -1,
            gpu = gpu.value,
            note = "GPU offload requires a CUDA-built libllama — rebuild llama.cpp with -DGGML_CUDA=ON, "
                .. "then set MEMO_GEN_NGL=-1.",
        }
    end
    return {
        ok = true, device = "cpu", model = "gemma-3-1b-it", quant = "Q4_K_M", n_gpu = 0,
        gpu = (gpu.ok and gpu.value) or nil,
    }
end

return M
