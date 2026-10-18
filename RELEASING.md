# Releasing luamemo

A release is one manual run of the **Release** workflow. The workflow tests the code,
builds the rock and the prebuilt GGUF runtimes, tags the release and publishes it.
Every step can be checked locally first.

## Before the run (on `main`)

1. Set the version in `luamemo/init.lua` (`M.VERSION = "X.Y.Z"`).
2. Write its section in `CHANGELOG.md`: `## [X.Y.Z] — unreleased` (the workflow
   replaces "unreleased" with the date).
3. Generate the rockspec: `luajit eval/release/rockspec.lua X.Y.Z` (it lists every
   `luamemo/**/*.lua`; `--check` tells you whether the committed one is current).
4. Check it locally:
   ```bash
   luajit eval/tests/run.lua                               # the suite
   bash eval/release/smoke.sh luamemo-X.Y.Z-1.rockspec     # the rock, installed and used
   ```
5. Commit, push, and wait for **CI** to pass. CI runs the suite on Ubuntu, with and
   without lua-cjson, plus the smoke test. A macOS job also runs, but it doesn't
   block yet.

## The run

**Actions → Release → Run workflow**: version `X.Y.Z`; tick **publish** to upload to
luarocks.org too. The publish step needs the repository secret `LUAROCKS_API_KEY`
(Settings → Secrets and variables → Actions) — a luarocks.org API key, never stored
anywhere else.

The workflow does this, and stops at the first failure:

1. **Checks:** the version is `luamemo.VERSION`, its rockspec is current, the
   CHANGELOG has its section, and no tag `vX.Y.Z` exists yet.
2. **CI:** the whole of CI on that commit.
3. **GGUF runtimes:** `eval/release/gguf_bundle.sh` runs on Linux x86_64 and on
   macOS arm64. It builds llama.cpp at `M.LLAMA_TAG` (in
   `luamemo/embedders/native/bundle.lua`) and the shim.
4. **Release commit:** one commit holds the runtimes' checksums
   (`luamemo/embedders/native/bundles.lua`) and the CHANGELOG date. Only the tag
   `vX.Y.Z` points to it; `main` is left as it is.
5. **The source rock**, packed from that tag. It gets the smoke test, exactly as it
   will be published.
6. **The GitHub Release:** the rock, the rockspec, the runtimes with their `.sha256`
   files, and notes taken from the CHANGELOG section.
7. With **publish**: `luarocks upload`.

`memo gguf install` (offered by `memo calibrate`) downloads the runtime for its
machine from that release. It refuses any download that doesn't match the checksum
the installed rock carries.

## After

- Install it on a machine and use it, e.g. `sudo luarocks install luamemo`, then
  `memo calibrate` in a project.
- Start the next version on `main`: bump `M.VERSION`, open its CHANGELOG section, and
  generate its rockspec.
