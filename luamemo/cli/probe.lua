-- luamemo.cli.probe
--
-- Host environment probes used by `memo init` and `memo doctor`. Pure
-- shell-out, no external deps. Each probe returns { ok = bool, value = ?, err = ? }.

local M = {}

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
    local out = read_cmd("curl -fsS --max-time 2 " .. url .. "/api/version")
    if not out or out == "" then
        return { ok = false, err = "no response from " .. url }
    end
    return { ok = true, value = url }
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
        "-not -path '*/.venv/*' -not -path '*/__pycache__/*' " ..
        "| sed -n 's/.*\\.\\([A-Za-z0-9]\\+\\)$/\\1/p' | sort | uniq -c | sort -rn | head -20",
        root))
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
        "-not -path '*/node_modules/*' 2>/dev/null | head -3", root)) or ""
    local multilingual_hint = mlines ~= ""
    return { ext_census = ext_census, multilingual_hint = multilingual_hint }
end

return M
