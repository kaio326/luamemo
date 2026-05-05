-- Smoke test for eval.paraphrase deterministic generator.
package.path = "./?.lua;./?/init.lua;eval/?.lua;" .. package.path
local pp = require("paraphrase")

local function show(label, s)
    print(string.format("  %-10s %s", label, s))
end

local cases = {
    "Did I buy the car at the big dealership?",
    "What movie did you like best in 2024?",
    "I went to the doctor on Monday.",
    "My company is in Toronto.",
    "Sphinx of black quartz, judge my vow.",
}

for _, q in ipairs(cases) do
    print("Q: " .. q)
    local v = pp.variants(q, 3)
    show("v1 syn", v[1])
    show("v2 reord", v[2])
    show("v3 drop",  v[3])
    -- Determinism: rerun must produce identical output
    local v2 = pp.variants(q, 3)
    for i = 1, 3 do
        assert(v[i] == v2[i], "non-determinism at variant " .. i)
    end
    -- Each variant must differ from the original
    for i = 1, 3 do
        assert(v[i] ~= q,
            "variant " .. i .. " did not change input: " .. q)
    end
    print("")
end

-- N>3 path
local v6 = pp.variants("Did I buy the big car?", 6)
assert(#v6 == 6, "n=6 should produce 6 variants")
print("n=6 path OK (last variant: " .. v6[6] .. ")")

print("ALL paraphrase smokes passed.")
