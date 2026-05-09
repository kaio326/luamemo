-- luamemo.async
--
-- Minimal cooperative task scheduler for plain Lua over socket.select().
-- Zero new dependencies: luasocket is already required by luamemo.http
-- in the plain-Lua path, so socket.select() is always available.
--
-- Intended use: fan-out N HTTP embedding calls in write_many() so the
-- total latency approaches 1 × embed_latency instead of N × embed_latency.
--
-- In OpenResty this module is never invoked — resty.http is non-blocking
-- via cosockets and the scheduler would only add overhead.
--
-- API
-- ---
--   async.wait(sock, event)          -- yield from within a task coroutine
--   async.run_all(tasks, timeout_ms) -- run all tasks concurrently
--
-- Tasks are zero-argument functions. They communicate with the scheduler
-- by calling async.wait(sock, "read"|"write") whenever they would block
-- on a socket. The scheduler resumes them when the socket is ready.
--
-- Return value of run_all: array (parallel to tasks) of
--   { ok = bool, result = first_return_value_of_task }

local socket = require("socket")

local M = {}

--- Yield from within a running task coroutine until sock is ready.
-- event must be "read" or "write".
-- This is a no-op when called outside a coroutine context (e.g. in tests).
function M.wait(sock, event)
    coroutine.yield(sock, event)
end

--- Run all task functions concurrently, waiting at most timeout_ms ms total.
-- @param tasks       table     Array of zero-argument functions
-- @param timeout_ms  number    Wall-clock timeout in milliseconds (default 30000)
-- @return table                Array of { ok = bool, result = any }
function M.run_all(tasks, timeout_ms)
    timeout_ms  = timeout_ms or 30000
    local deadline = socket.gettime() + timeout_ms / 1000

    local n       = #tasks
    local coros   = {}   -- [i] = coroutine
    local results = {}   -- [i] = { ok, result }
    local waiting = {}   -- [i] = { sock, event } | nil

    -- Create one coroutine per task.
    for i = 1, n do
        coros[i] = coroutine.create(tasks[i])
    end

    -- First resume: start all tasks. They either complete immediately or
    -- yield with (sock, event) to indicate they need I/O.
    for i = 1, n do
        local ok, a, b = coroutine.resume(coros[i])
        if coroutine.status(coros[i]) == "dead" then
            -- Task finished (ok=true, a=return value) or raised error (ok=false, a=msg)
            results[i] = { ok = ok, result = a }
        elseif ok and a then
            -- Yielded: waiting on socket a for event b
            waiting[i] = { sock = a, event = b or "read" }
        else
            -- Yielded with no socket, or internal error
            results[i] = { ok = false, result = tostring(a) }
        end
    end

    -- Event loop: iterate until all tasks finish or the deadline is reached.
    while true do
        local read_list  = {}
        local write_list = {}
        local sock_to_i  = {}   -- tostring(sock) -> coroutine index
        local any        = false

        for i = 1, n do
            if waiting[i] then
                any = true
                local s   = waiting[i].sock
                local key = tostring(s)
                sock_to_i[key] = i
                if waiting[i].event == "write" then
                    write_list[#write_list + 1] = s
                else
                    read_list[#read_list + 1] = s
                end
            end
        end

        if not any then break end

        local remaining = deadline - socket.gettime()
        if remaining <= 0 then break end

        -- Poll with a short cap so we don't block indefinitely when sockets
        -- are slow — the outer deadline check will catch a true timeout.
        local rr, wr = socket.select(read_list, write_list, math.min(remaining, 0.05))

        -- Build a deduplicated resume list (a socket may appear in both lists
        -- after a simultaneous read+write event on the same FD).
        local seen     = {}
        local to_resume = {}
        for _, s in ipairs(rr or {}) do
            local key = tostring(s)
            if not seen[key] then seen[key] = true; to_resume[#to_resume + 1] = sock_to_i[key] end
        end
        for _, s in ipairs(wr or {}) do
            local key = tostring(s)
            if not seen[key] then seen[key] = true; to_resume[#to_resume + 1] = sock_to_i[key] end
        end

        for _, i in ipairs(to_resume) do
            if waiting[i] then  -- guard against double-resume
                waiting[i] = nil
                local ok, a, b = coroutine.resume(coros[i])
                if coroutine.status(coros[i]) == "dead" then
                    results[i] = { ok = ok, result = a }
                elseif ok and a then
                    waiting[i] = { sock = a, event = b or "read" }
                else
                    results[i] = { ok = false, result = tostring(a) }
                end
            end
        end
    end

    -- Any coroutines still waiting have timed out. Best-effort close their sockets.
    for i = 1, n do
        if not results[i] then
            results[i] = { ok = false, result = "async: task timed out" }
            if waiting[i] and waiting[i].sock then
                pcall(function() waiting[i].sock:close() end)
            end
        end
    end

    return results
end

return M
