-- Smoke test for luamemo.rerankers.cross_encoder.
-- Does NOT require a running TEI sidecar — we monkey-patch
-- resty.http to return canned responses and verify the parser
-- handles both TEI native and Cohere/Jina shapes.
package.path = "./?.lua;./?/init.lua;" .. package.path

local cjson = require("cjson.safe")

-- Shim resty.http BEFORE the adapter requires it.
local fake_response  -- set per test
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, _, _) return fake_response end,
        }
    end,
}

-- Provide a minimal eval/_resty_http_shim if cross_encoder ever switches
package.loaded["eval._resty_http_shim"] = package.loaded["resty.http"]

local ce = require("luamemo.rerankers.cross_encoder")

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format("ASSERT FAIL: %s expected=%s got=%s",
            msg or "", tostring(b), tostring(a)), 2)
    end
end

local hits = {
    { id = 1, title = "alpha", body = "first candidate body" },
    { id = 2, title = "beta",  body = "second candidate body" },
    { id = 3, title = "gamma", body = "third candidate body" },
}

-- Test 1: TEI native shape ([{index,score}, ...])
fake_response = {
    status = 200,
    body = cjson.encode({
        { index = 2, score = 0.91 },
        { index = 0, score = 0.62 },
        { index = 1, score = 0.05 },
    }),
}
local out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
assert(not err, "tei: unexpected err: " .. tostring(err))
assert_eq(#out, 3, "tei: result count")
assert_eq(out[1].index, 2, "tei: row1.index")
assert(math.abs(out[1].score - 0.91) < 1e-6, "tei: row1.score")
assert_eq(out[2].index, 0, "tei: row2.index")
print("ok: TEI native shape parsed")

-- Test 2: Cohere/Jina shape ({results:[{index,relevance_score},...]})
fake_response = {
    status = 200,
    body = cjson.encode({
        results = {
            { index = 1, relevance_score = 0.88 },
            { index = 2, relevance_score = 0.40 },
        },
    }),
}
out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
assert(not err, "cohere: unexpected err: " .. tostring(err))
assert_eq(#out, 2, "cohere: result count")
assert_eq(out[1].index, 1, "cohere: row1.index")
assert(math.abs(out[1].score - 0.88) < 1e-6, "cohere: row1.score")
print("ok: Cohere/Jina shape parsed")

-- Test 3: missing rerank_url returns error
out, err = ce.rerank("q", hits, {})
assert(out == nil, "missing url: out should be nil")
assert(err and err:find("rerank_url not set"), "missing url: err msg: " .. tostring(err))
print("ok: missing rerank_url errors clearly")

-- Test 4: HTTP non-2xx propagated
fake_response = { status = 503, body = "Service Unavailable" }
out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
assert(out == nil, "http503: out should be nil")
assert(err and err:find("HTTP 503"), "http503: err msg: " .. tostring(err))
print("ok: HTTP 503 propagated")

-- Test 5: malformed JSON returns error
fake_response = { status = 200, body = "not json at all" }
out, err = ce.rerank("q", hits, { rerank_url = "http://x/rerank" })
assert(out == nil, "badjson: out should be nil")
assert(err, "badjson: err set")
print("ok: malformed JSON errors clearly")

-- Test 6: empty hits short-circuits
out, err = ce.rerank("q", {}, { rerank_url = "http://x/rerank" })
assert(not err, "empty: no err")
assert_eq(#out, 0, "empty: out is empty")
print("ok: empty hits short-circuits")

print("ALL cross_encoder smokes passed.")
