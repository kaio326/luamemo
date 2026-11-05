-- luamemo/evalkit.lua — the SHA-256 of this release's eval kit (eval/release/eval_kit.sh
-- builds it; `memo eval install` checks the download against it). Empty in a checkout:
-- the release workflow writes the release's checksum here, in the commit its tag points
-- to, so a rock carries exactly its own (as bundles.lua does for the GGUF runtimes).
--   { version = "<version>", sha256 = "<hex>", asset = "luamemo-evalkit-<version>.tar.gz" }
-- Used only when `version` is luamemo.VERSION.
return {}
