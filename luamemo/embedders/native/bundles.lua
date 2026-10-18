-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release (eval/release/gguf_bundle.sh builds them; `memo gguf install` checks the
-- download against them). Empty in a checkout: the release workflow writes the release's
-- checksums here, in the commit its tag points to, so a rock carries exactly its own.
--   { version = "<version>",
--     ["<os>-<arch>"] = { sha256 = "<hex>", asset = "luamemo-gguf-<version>-<os>-<arch>.tar.gz" } }
-- Used only when `version` is luamemo.VERSION.
return {}
