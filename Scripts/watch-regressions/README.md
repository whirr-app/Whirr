# Watch host regressions

This macOS runner compiles selected production Watch model files against Core debug objects and
host stubs, then runs nine standalone regression programs. It covers download callbacks,
pagination, playback policy, download groups, navigation, phone browsing, Home projections, the
chapter list and the connectivity refresh wake's release rule.
The full-model programs substitute `WatchCompanionStore` as well as audio and ownership
transport; the production companion store is not compiled by this runner. It does not build the
Watch app or exercise a physical Watch.

## Run

Use the Xcode-selected Swift toolchain. From the repository root:

```sh
mkdir -p Packages/Core/.build/mcache Packages/Core/.build/xdg
CLANG_MODULE_CACHE_PATH="$PWD/Packages/Core/.build/mcache" \
XDG_CACHE_HOME="$PWD/Packages/Core/.build/xdg" \
  swift build --package-path Packages/Core --target WatchPlayback --disable-sandbox
python3 Scripts/watch-regressions/run.py
```

The runner sets both cache variables itself. It asks `swift build --show-bin-path` for Core's debug
output directory, falling back to `Packages/Core/.build/arm64-apple-macosx/debug` when the lookup is
unavailable. Build Core in its default scratch directory with the same toolchain; building
`--target WatchPlayback` covers the four linked targets, and a full build also works. A missing
module, missing object or empty target object list fails before compilation. Objects come from
SwiftPM's `output-file-map.json` for the four explicit targets in `MANIFEST`, excluding stale
unlisted objects. The runner does not rebuild Core, so rebuild after changing Core sources.

Each compile and each program execution has a 120-second timeout. A failed compile, assertion,
launch or timeout exits non-zero and names the program; successful programs print `PASS`.
Generated modules, combined sources and executables live in an automatically removed temporary
directory. CI runs this beside the standalone Watch build in `.github/workflows/tests.yml` and
retains both Core-build and regression logs in the App artifacts.

An enclosing execution sandbox can deny Swift's Observation macro process
(`sandbox_apply: Operation not permitted`). Cache redirection and SwiftPM's `--disable-sandbox`
do not fix a denied `swiftc` macro process; the same runner needs execution permission in an
environment that permits it.

## Add a program

1. Add `<Name>Regression.swift` here with an `@main` entry point and assertions that fail the
   process. Wait with `hostAwait` or `hostAwaitQuiescence` from `HostWaiting.swift`, which every
   program compiles; `WaiterPatternTests` scans this folder and fails on a hand-written yield loop
   or fixed sleep.
2. Add its stem to `MANIFEST["programs"]` in `run.py`. `sources` lists Watch-app filenames
   relative to `App/WhirrWatch Watch App`; the runner appends the matching regression file
   automatically.
3. Use `shared: True` only when the program needs the full model/controller set, hardware stubs
   and shared journal. Add new Watch model files to `MANIFEST["shared"]` or the program's
   `sources`. `cross_target` filenames are relative to `App/WatchShared`; `stubs` are relative
   to this folder.
4. If an existing file-private probe requires a single compilation unit, put its production
   source filenames in `combined`. These precede the regression in a temporary Swift file.
   Prefer public or internal seams for new coverage. Do not also list those files in `sources`
   or `shared`.
5. If linking needs another Core target, add it to `core_targets` and rebuild Core. Each listed
   target must supply a module and at least one object in its SwiftPM output map.
6. Run the commands above, `python3 -m py_compile Scripts/watch-regressions/run.py`,
   `Scripts/check-format.sh` and `git diff --check`.

Runner failure-path checks need only Python:

```sh
python3 Scripts/watch-regressions/test_run.py
```

A proposed WhirrWatchTests target would
migrate this coverage to direct Watch-app tests after owner approval and an Xcode-created test
bundle.
