-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the
-- download against them). Used only when `version` is luamemo.VERSION.
return {
    version = "0.5.4",
    ["linux-x86_64"] = { sha256 = "cbdc13c2bfbc9488cfe5880171dbed11496faab788694757e8cc2b68da5951c3", asset = "luamemo-gguf-0.5.4-linux-x86_64.tar.gz" },
    ["macos-arm64"] = { sha256 = "2617f0362263c5f221bbe4772ef31a9eba387cc0a41cdc256ecd171618b3e961", asset = "luamemo-gguf-0.5.4-macos-arm64.tar.gz" },
}
