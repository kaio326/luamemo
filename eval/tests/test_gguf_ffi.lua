-- eval/tests/test_gguf_ffi.lua
-- Phase 7 — in-process EmbeddingGemma FFI embedder.
--   * loads cleanly under BOTH VMs; under PUC lua5.1 returns a graceful error
--   * under LuaJIT with the shim + a GGUF model present: 768-d L2-normalised
--     vectors, Matryoshka truncation renormalised. (Skips those live checks if
--     the shim/model are absent — they are built/downloaded locally, gitignored.)
--
-- Usage:
--   MEMO_GGUF_MODEL=~/models/embeddinggemma-300M-Q8_0.gguf luajit eval/tests/test_gguf_ffi.lua

package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(l, ok, d) if ok then io.write("[PASS] "..l.."\n"); pass=pass+1
    else io.write("[FAIL] "..l..(d and (" — "..d) or "").."\n"); fail=fail+1 end end

local ok_req, g = pcall(require, "luamemo.embedders.gguf_ffi")
check("module loads without error", ok_req, tostring(g))
if not ok_req then io.write("\n0 passed, 1 failed\n"); os.exit(1) end

local has_ffi = pcall(require, "ffi")

if not has_ffi then
    local v, err = g.embed("x", {})
    check("under lua5.1: embed returns graceful error (no crash)",
        v == nil and tostring(err):find("LuaJIT", 1, true) ~= nil, tostring(err))
    io.write(string.format("\n%d passed, %d failed  (lua5.1: FFI path skipped)\n", pass, fail))
    if fail > 0 then os.exit(1) end
    return
end

-- LuaJIT path: need the shim + a model to exercise the real embed.
local model = os.getenv("MEMO_GGUF_MODEL")
if not model or model == "" then model = (os.getenv("HOME") or "") .. "/models/embeddinggemma-300M-Q8_0.gguf" end
local shim = "luamemo/embedders/native/gguf_shim.so"
local function exists(p) local f=io.open(p,"r"); if f then f:close(); return true end return false end

if not (exists(model) and exists(shim)) then
    io.write(string.format("[SKIP] live embed — shim or model absent (shim=%s model=%s)\n",
        tostring(exists(shim)), tostring(exists(model))))
    io.write(string.format("\n%d passed, %d failed  (LuaJIT: live embed skipped)\n", pass, fail))
    if fail > 0 then os.exit(1) end
    return
end

local cfg = { embedder_model = model }
local v, err = g.embed("Never commit or push autonomously.", cfg)
check("embed returns a vector", type(v) == "table" and #v > 0, tostring(err))
if type(v) == "table" and #v > 0 then
    check("native dim is 768 (EmbeddingGemma)", #v == 768, tostring(#v))
    local ss = 0; for i=1,#v do ss = ss + v[i]*v[i] end
    check("output is L2-normalised", math.abs(math.sqrt(ss) - 1.0) < 1e-3, string.format("%.5f", math.sqrt(ss)))
end
local v2 = g.embed("test", { embedder_model = model, embed_dim = 256 })
if type(v2) == "table" then
    local ss2 = 0; for i=1,#v2 do ss2 = ss2 + v2[i]*v2[i] end
    check("Matryoshka truncation to 256 dims, renormalised", #v2 == 256 and math.abs(math.sqrt(ss2)-1.0) < 1e-3,
        string.format("dim=%d L2=%.4f", #v2, math.sqrt(ss2)))
end
check("selftest passes", (g.selftest(cfg)))

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
