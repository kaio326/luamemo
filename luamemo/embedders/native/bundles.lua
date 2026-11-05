-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the
-- download against them). Used only when `version` is luamemo.VERSION.
return {
    version = "0.5.2",
    ["linux-x86_64"] = { sha256 = "a1a0e1c56f36feff0b807c60ec31d8130e50bd0f7f55a8d489bc7b0846a465cd", asset = "luamemo-gguf-0.5.2-linux-x86_64.tar.gz" },
    ["macos-arm64"] = { sha256 = "769054b36a8fbe0e33e235115091348ec6e5dc490954691d18b529462a48f7dc", asset = "luamemo-gguf-0.5.2-macos-arm64.tar.gz" },
}
