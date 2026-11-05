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
4. **Eval kit:** `eval/release/eval_kit.sh` packs the benchmark runners, the
   personalization set, the fixtures, the baselines and the dataset list (the files
   `luamemo/cli/eval.lua` lists in `M.KIT_FILES`) into
   `luamemo-evalkit-X.Y.Z.tar.gz`.
5. **Release commit:** one commit holds the runtimes' checksums
   (`luamemo/embedders/native/bundles.lua`), the eval kit's (`luamemo/evalkit.lua`,
   by `eval/release/write_evalkit.lua`) and the CHANGELOG date. Only the tag `vX.Y.Z`
   points to it; `main` is left as it is.
6. **The source rock**, packed from that tag. It gets the smoke test, exactly as it
   will be published.
7. **The GitHub Release:** the rock, the rockspec, the runtimes and the eval kit with
   their `.sha256` files, and notes taken from the CHANGELOG section.
8. With **publish**: `luarocks upload`.

`memo gguf install` (offered by `memo calibrate`) downloads the runtime for its
machine from that release; `memo eval install` downloads the eval kit. Both refuse
any download that doesn't match the checksum the installed rock carries. (The eval
kit's release steps were tested against a local asset — `eval/tests/test_eval_cli.lua`
— and first run for real in 0.5.2's release.)

To publish new benchmark numbers, run `memo eval run --tier standard --embedder
gguf,hash,ollama,tei` and `memo eval run membench longmemeval_s --embedder hash` on the
release candidate, then merge each run's `summary.json` `results[bench][label]` into
`eval/baselines.json` (keep its `_comment`, `command`, `luamemo`, `machine` and
`measured` fields up to date) before the release: the kit carries the baselines users'
runs are compared with. Do not copy one summary over the file — a run holds only its own
benchmarks and embedders, so that would delete the other rows.

## After

- Install it on a machine and use it, e.g. `sudo luarocks install luamemo`, then
  `memo calibrate` in a project.
- luarocks.org takes the module's summary and description from the *first* rockspec ever
  uploaded and never updates them from a later one (they still showed the 0.1-era text
  after 0.5.1), and the site has no API for it — an API key reaches only the upload
  endpoints; the edit form needs a login session. So with **publish**, the last step of
  the workflow only *checks*: when the page's summary differs from the rockspec's it
  warns, and the job summary holds the text to paste (summary ≤ 512 characters,
  description ≤ 5120) and the link `https://luarocks.org/edit/modules/<user>/luamemo`.
  Paste it there, logged in as the owner; a page that is already current needs nothing.
  (The step never fails the release; `eval/release/luarocks_text.lua` extracts the text.)
- When a release adds a feature, re-read that description in the template first: it is
  what luarocks.org shows.
- Start the next version on `main`: bump `M.VERSION`, open its CHANGELOG section, and
  generate its rockspec.
