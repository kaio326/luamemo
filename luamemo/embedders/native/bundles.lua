-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the
-- download against them). Used only when `version` is luamemo.VERSION.
return {
    version = "0.5.3",
    ["linux-x86_64"] = { sha256 = "d74a6c74283397c03167b7a65f35e296d425cafadb94f331e8e28d6530d6e976", asset = "luamemo-gguf-0.5.3-linux-x86_64.tar.gz" },
    ["macos-arm64"] = { sha256 = "e2f9504c9eca44f6ca8069714452785596af78cee0f359e78225dcb262ef71a2", asset = "luamemo-gguf-0.5.3-macos-arm64.tar.gz" },
}
