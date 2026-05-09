-- luamemo/lsh.lua
-- Random-hyperplane LSH for cosine similarity — pure Lua 5.1, zero deps.
--
-- Algorithm: Charikar (2002) sign-random-projection LSH, which preserves the
-- cosine distance measure. A vector v is hashed by computing sign(v · h_i)
-- for K random unit hyperplanes h_i, producing a K-bit key (stored as a
-- binary string). L independent tables are maintained; a query unions the
-- matching buckets across all L tables to form a small candidate set.
--
-- Tuning guidelines (defaults: L=8, K=12):
--   More L → higher recall, more memory, slightly slower insert/query.
--   More K → smaller buckets (faster query), slightly lower recall per table.
--   8 tables × 12 bits gives ≈95% recall for 50k vectors of dim=384
--   with roughly 100–300 candidates per query.
--
-- Public API:
--   local lsh = require("luamemo.lsh")
--   local idx = lsh.new(dim, L, K)         -- create index
--   idx:insert(id, vec)                    -- add / update a vector
--   idx:remove(id)                         -- mark as deleted (lazy)
--   local ids = idx:query(vec, max_n)      -- return candidate ID array
--   idx:rebuild(entries)                   -- full rebuild from {id, vec} array

local M = {}

-- ---------------------------------------------------------------------------
-- Module-level init: seed math.random once so hyperplanes differ across runs.
-- Combine os.time() (epoch seconds) with the fractional part of os.clock()
-- (CPU time, sub-second) to reduce same-second collisions between processes.
-- ---------------------------------------------------------------------------
math.randomseed(os.time() + math.floor((os.clock() % 1.0) * 1e6))

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local TWO_PI = 2.0 * math.pi

-- Box-Muller transform: returns one standard-normal random sample.
-- Loops to exclude the degenerate u1=0 case (probability ~= 0 in IEEE 754).
local function randn()
    local u1
    repeat u1 = math.random() until u1 > 0
    local u2 = math.random()
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(TWO_PI * u2)
end

-- Generate a unit-length random hyperplane of `dim` dimensions.
local function random_hyperplane(dim)
    local h, norm2 = {}, 0
    for i = 1, dim do
        local x = randn()
        h[i]  = x
        norm2 = norm2 + x * x
    end
    local inv = norm2 > 0 and (1.0 / math.sqrt(norm2)) or 0.0
    for i = 1, dim do h[i] = h[i] * inv end
    return h
end

-- Hash vector `v` using the K hyperplanes in `hplanes`.
-- Returns a K-character string of '0'/'1' characters.
local function hash_vec(v, hplanes)
    local bits = {}
    for ki, h in ipairs(hplanes) do
        local dot = 0
        for j = 1, #h do dot = dot + (v[j] or 0) * h[j] end
        bits[ki] = dot >= 0 and "1" or "0"
    end
    return table.concat(bits)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Create a new LSH index.
-- @param dim  Embedding dimension (positive integer).
-- @param L    Number of hash tables (default 8).
-- @param K    Bits per hash key / hyperplanes per table (default 12).
-- @return     Index object.
function M.new(dim, L, K)
    assert(type(dim) == "number" and dim > 0,
        "lsh.new: dim must be a positive number, got " .. tostring(dim))
    L = tonumber(L) or 8
    K = tonumber(K) or 12

    -- Generate L × K random unit hyperplanes.
    local hplane_tables = {}
    for t = 1, L do
        hplane_tables[t] = {}
        for k = 1, K do
            hplane_tables[t][k] = random_hyperplane(dim)
        end
    end

    local idx = {
        dim           = dim,
        L             = L,
        K             = K,
        hplane_tables = hplane_tables,
        -- tables[t][hash_key_string] = { id, id, ... }
        tables        = {},
        -- id_to_slots[id] = { {t, key}, ... }  — one entry per hash table.
        -- Used for O(1) upsert (remove then re-insert).
        id_to_slots   = {},
        -- deleted[id] = true: id was removed but bucket entries are still
        -- present (lazy deletion, cleared on rebuild).
        deleted       = {},
        -- Approximate count of live (non-deleted) entries.
        size          = 0,
    }
    for t = 1, L do idx.tables[t] = {} end

    setmetatable(idx, { __index = M })
    return idx
end

--- Insert (or update) a vector.
-- If `id` already exists, its old slots are invalidated first (upsert).
-- @param id   Unique integer ID.
-- @param vec  Lua number array of length idx.dim.
function M:insert(id, vec)
    if not id or not vec then return end
    -- Remove stale entry so slot table stays correct.
    if self.id_to_slots[id] then
        self:remove(id)
    end
    local slots = {}
    for t = 1, self.L do
        local key    = hash_vec(vec, self.hplane_tables[t])
        local bucket = self.tables[t][key]
        if not bucket then
            bucket = {}
            self.tables[t][key] = bucket
        end
        bucket[#bucket + 1] = id
        slots[#slots + 1]   = { t, key }
    end
    self.id_to_slots[id] = slots
    self.deleted[id]     = nil
    self.size            = self.size + 1
end

--- Mark `id` as deleted (lazy — bucket entries stay until rebuild).
-- Future queries will skip this id.
function M:remove(id)
    if not self.id_to_slots[id] then return end
    self.deleted[id]     = true
    self.id_to_slots[id] = nil
    self.size            = math.max(0, self.size - 1)
end

--- Query: return up to `max_results` candidate IDs near `vec`.
-- Unions matching buckets across all L tables; results are deduplicated.
-- @param vec         Query vector (Lua number array).
-- @param max_results Upper bound on returned candidates (default 200).
-- @return            Array of integer IDs (unordered).
function M:query(vec, max_results)
    max_results = max_results or 200
    local seen   = {}
    local result = {}
    for t = 1, self.L do
        local key    = hash_vec(vec, self.hplane_tables[t])
        local bucket = self.tables[t][key]
        if bucket then
            for _, id in ipairs(bucket) do
                if not seen[id] and not self.deleted[id] then
                    seen[id]           = true
                    result[#result + 1] = id
                    if #result >= max_results then return result end
                end
            end
        end
    end
    return result
end

--- Full rebuild from an array of entries, discarding all existing data.
-- @param entries  Array of { id=<integer>, vec=<number array> } tables.
function M:rebuild(entries)
    for t = 1, self.L do self.tables[t] = {} end
    self.id_to_slots = {}
    self.deleted     = {}
    self.size        = 0
    for _, e in ipairs(entries) do
        if e.id and e.vec then
            self:insert(e.id, e.vec)
        end
    end
end

return M
