-- luamemo.projection_train  (Phase 5 — learned projection over hash features)
--
-- Learns a d×d matrix W that pulls (query, used-memory) hash vectors together and
-- pushes (query, ignored-memory) apart — a contrastive triplet objective over the
-- feedback triples. W is L2-regularised toward the IDENTITY, so an untrained/tiny
-- model stays == raw hash (the durable default). Inference is one mat-vec
-- (luamemo.embedders.hash_learned).
--
-- Unlike the reranker (Phase 4, which only reorders a retrieved pool), the
-- projection changes the VECTORS — a coverage lever: it can move a low-lexical-
-- overlap gold's vector toward the query, changing what is retrieved.
--
-- Versioned matrix artifact (path via MEMO_PROJECTION_W): save_version / promote /
-- rollback / load_current, mirroring luamemo.rerank_train.

local cjson = require("cjson.safe")

local M = {}

local PATH = (os.getenv("MEMO_PROJECTION_W") ~= "" and os.getenv("MEMO_PROJECTION_W"))
    or "luamemo/projection_W.json"

function M.identity(d)
    local m = {}
    for i = 1, d * d do m[i] = 0 end
    for i = 1, d do m[(i - 1) * d + i] = 1 end
    return { dim = d, m = m }
end

local function matvec(W, x)
    local d, m = W.dim, W.m
    local y = {}
    for i = 1, d do
        local base, s = (i - 1) * d, 0
        for j = 1, d do s = s + m[base + j] * x[j] end
        y[i] = s
    end
    return y
end
local function dot(a, b) local s = 0; for i = 1, #a do s = s + a[i] * b[i] end; return s end

-- examples = { { q = xq, p = xp, negs = { xn, ... } }, ... }  (x* are hash vectors)
-- opts: dim (required), lr (0.05), l2 (0.01), epochs (30), margin (0.1)
function M.train(examples, opts)
    opts = opts or {}
    local d      = opts.dim or (examples[1] and #examples[1].q) or 384
    local lr     = opts.lr or 0.05
    local l2     = opts.l2 or 0.01
    local epochs = opts.epochs or 30
    local margin = opts.margin or 0.1
    local W = M.identity(d)
    local m = W.m

    for _ = 1, epochs do
        for _, ex in ipairs(examples) do
            local xq, xp = ex.q, ex.p
            local a, b = matvec(W, xq), matvec(W, xp)
            for _, xn in ipairs(ex.negs or {}) do
                local c = matvec(W, xn)
                if (dot(a, b) - dot(a, c)) < margin then     -- margin violated
                    -- grad of (a·b - a·c) wrt W[i,j] = (b-c)[i]*xq[j] + a[i]*(xp-xn)[j]
                    for i = 1, d do
                        local bci, ai, base = b[i] - c[i], a[i], (i - 1) * d
                        for j = 1, d do
                            local idx   = base + j
                            local wij   = m[idx]
                            local prior = (i == j) and 1 or 0
                            local g     = bci * xq[j] + ai * (xp[j] - xn[j])
                            m[idx] = wij + lr * g - lr * l2 * (wij - prior)
                        end
                    end
                    a, b = matvec(W, xq), matvec(W, xp)      -- W moved; refresh
                end
            end
        end
    end
    return W
end

-- Mean triplet-margin loss (monitoring). Lower = better separation.
function M.loss(W, examples, margin)
    margin = margin or 0.1
    local total, n = 0, 0
    for _, ex in ipairs(examples) do
        local a, b = matvec(W, ex.q), matvec(W, ex.p)
        for _, xn in ipairs(ex.negs or {}) do
            local c = matvec(W, xn)
            local v = margin - (dot(a, b) - dot(a, c))
            total = total + (v > 0 and v or 0); n = n + 1
        end
    end
    return n > 0 and total / n or 0
end

-- ---- low-rank projection: W = I + U·V  (U: d×r, V: r×d) -----------------
-- For a large base (e.g. 768-d EmbeddingGemma) a full d×d W has far too many
-- params for sparse feedback; the low-rank residual keeps it tractable + cheap
-- (2·d·r params, one small mat-vec at inference). Consumed by
-- luamemo.embedders.projected (kind="lowrank").

-- Tiny deterministic PRNG so inits are reproducible AND both U and V get
-- gradient (a zero U would zero the V gradient).
local function lcg(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function() s = (s * 16807) % 2147483647; return s / 2147483647 end
end

function M.identity_lowrank(d, r)
    local U, V = {}, {}
    for i = 1, d * r do U[i] = 0 end
    for i = 1, r * d do V[i] = 0 end
    return { kind = "lowrank", dim = d, rank = r, U = U, V = V }
end

-- h = V·x (length r), Uh = U·h (length d)
local function lr_fwd(W, x)
    local d, r, U, V = W.dim, W.rank, W.U, W.V
    local h = {}
    for k = 1, r do local base, s = (k - 1) * d, 0; for j = 1, d do s = s + V[base + j] * x[j] end; h[k] = s end
    local Uh = {}
    for i = 1, d do local base, s = (i - 1) * r, 0; for k = 1, r do s = s + U[base + k] * h[k] end; Uh[i] = s end
    return h, Uh
end

-- Mean triplet-margin loss for a low-rank W (monitoring).
function M.loss_lowrank(W, examples, margin)
    margin = margin or 0.1
    local total, n = 0, 0
    for _, ex in ipairs(examples) do
        local _, Uq = lr_fwd(W, ex.q)
        for _, xn in ipairs(ex.negs or {}) do
            local _, Up = lr_fwd(W, ex.p)
            local _, Un = lr_fwd(W, xn)
            local F = 0
            for i = 1, #ex.q do F = F + (ex.q[i] + Uq[i]) * ((ex.p[i] + Up[i]) - (xn[i] + Un[i])) end
            local v = margin - F; total = total + (v > 0 and v or 0); n = n + 1
        end
    end
    return n > 0 and total / n or 0
end

-- Train W = I + U·V by pairwise triplet-margin ascent. examples as M.train.
-- opts: dim, rank (16), lr (0.05), l2 (0.001), epochs (30), margin (0.1), seed.
function M.train_lowrank(examples, opts)
    opts = opts or {}
    local d = opts.dim or (examples[1] and #examples[1].q) or 384
    local r = opts.rank or 16
    local lr, l2, epochs, margin = opts.lr or 0.05, opts.l2 or 0.001, opts.epochs or 30, opts.margin or 0.1
    local rand = lcg(opts.seed or 1234567)
    local init = opts.init_scale or 0.01
    local W = M.identity_lowrank(d, r)
    local U, V = W.U, W.V
    for i = 1, d * r do U[i] = (rand() - 0.5) * 2 * init end
    for i = 1, r * d do V[i] = (rand() - 0.5) * 2 * init end

    local function UtW(w)               -- (U^T w)[k] = sum_i U[i,k]·w[i]
        local out = {}
        for k = 1, r do out[k] = 0 end
        for i = 1, d do local base, wi = (i - 1) * r, w[i]; for k = 1, r do out[k] = out[k] + U[base + k] * wi end end
        return out
    end

    for _ = 1, epochs do
        for _, ex in ipairs(examples) do
            local xq, xp = ex.q, ex.p
            local hq, Uhq = lr_fwd(W, xq)
            for _, xn in ipairs(ex.negs or {}) do
                local hp = (lr_fwd(W, xp))
                local hn = (lr_fwd(W, xn))
                local dh = {}; for k = 1, r do dh[k] = hp[k] - hn[k] end
                local UDh = {}
                for i = 1, d do local base, s = (i - 1) * r, 0; for k = 1, r do s = s + U[base + k] * dh[k] end; UDh[i] = s end
                local zq, dx, dvec = {}, {}, {}
                for i = 1, d do zq[i] = xq[i] + Uhq[i]; dx[i] = xp[i] - xn[i]; dvec[i] = dx[i] + UDh[i] end
                local F = 0; for i = 1, d do F = F + zq[i] * dvec[i] end
                if F < margin then
                    local Utd, Utzq = UtW(dvec), UtW(zq)   -- computed from pre-update U
                    for i = 1, d do            -- dF/dU[i,k] = xq[i]dh[k] + dx[i]hq[k] + UDh[i]hq[k] + Uhq[i]dh[k]
                        local base, xqi, dxi, UDhi, Uhqi = (i - 1) * r, xq[i], dx[i], UDh[i], Uhq[i]
                        for k = 1, r do
                            local idx = base + k
                            local g = xqi * dh[k] + dxi * hq[k] + UDhi * hq[k] + Uhqi * dh[k]
                            U[idx] = U[idx] + lr * g - lr * l2 * U[idx]
                        end
                    end
                    for k = 1, r do            -- dF/dV[k,j] = Utd[k]xq[j] + Utzq[k]dx[j]
                        local base, a, b = (k - 1) * d, Utd[k], Utzq[k]
                        for j = 1, d do
                            local idx = base + j
                            V[idx] = V[idx] + lr * (a * xq[j] + b * dx[j]) - lr * l2 * V[idx]
                        end
                    end
                    hq, Uhq = lr_fwd(W, xq)    -- W moved; refresh for the next negative
                end
            end
        end
    end
    return W
end

-- --- versioned artifact --------------------------------------------------
function M.load_artifact()
    local f = io.open(PATH, "r")
    if not f then return { current = nil, previous = nil, versions = {}, order = {} } end
    local s = f:read("*a"); f:close()
    return cjson.decode(s) or { current = nil, previous = nil, versions = {}, order = {} }
end
function M.save_artifact(a)
    local f = io.open(PATH, "w"); if not f then return false end
    f:write(cjson.encode(a)); f:close(); return true
end
function M.save_version(W, meta)
    local a = M.load_artifact()
    a.order = a.order or {}
    local id = "v" .. (#a.order + 1)
    a.versions[id] = { W = W, score = meta and meta.score or nil,
        note = meta and meta.note or nil, created = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    a.order[#a.order + 1] = id
    M.save_artifact(a)
    local ok, hl = pcall(require, "luamemo.embedders.hash_learned"); if ok then hl.reset_cache() end
    return id
end
function M.promote(id)
    local a = M.load_artifact()
    if not a.versions[id] then return nil, "promote: no such version " .. tostring(id) end
    a.previous, a.current = a.current, id
    M.save_artifact(a)
    local ok, hl = pcall(require, "luamemo.embedders.hash_learned"); if ok then hl.reset_cache() end
    return true
end
function M.rollback()
    local a = M.load_artifact()
    if not a.previous then return nil, "rollback: no previous version" end
    a.current, a.previous = a.previous, a.current
    M.save_artifact(a)
    local ok, hl = pcall(require, "luamemo.embedders.hash_learned"); if ok then hl.reset_cache() end
    return a.current
end
function M.load_current()
    local a = M.load_artifact()
    if a.current and a.versions[a.current] then return a.versions[a.current].W end
    return nil
end

return M
