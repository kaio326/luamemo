-- luamemo/embedders/native/bundles.lua — the SHA-256 of each prebuilt GGUF runtime of
-- this release, written by eval/release/write_bundles.lua (`memo gguf install` checks the
-- download against them). Used only when `version` is luamemo.VERSION.
return {
    version = "0.5.0",
    ["linux-x86_64"] = { sha256 = "f6b2d7a72bebde8105b1db0b3c12dc3d2b65bedb2885dd91a656838c27601998", asset = "luamemo-gguf-0.5.0-linux-x86_64.tar.gz" },
    ["macos-arm64"] = { sha256 = "1c0736e582021d9e73e137667d9d571570a8e8c92f8c66fc08f3c7b04789b7e6", asset = "luamemo-gguf-0.5.0-macos-arm64.tar.gz" },
}
