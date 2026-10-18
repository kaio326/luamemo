-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the
-- download against them). Used only when `version` is luamemo.VERSION.
return {
    version = "0.5.1",
    ["linux-x86_64"] = { sha256 = "b9e99ab0ec456e334d093d1d6f392ce3b3c7cdc425258e5d2dfedd62df2c9333", asset = "luamemo-gguf-0.5.1-linux-x86_64.tar.gz" },
    ["macos-arm64"] = { sha256 = "46742681cc5ad9fc83870ca1a64e774fb8b05d762dae239c0b34da758beaa8f1", asset = "luamemo-gguf-0.5.1-macos-arm64.tar.gz" },
}
