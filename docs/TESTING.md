# Testing contract

Use the smallest lane that exercises the changed behavior. Record the lane, command, toolchain,
and result rather than treating a retry as a replacement for the first run.

## Smallest relevant lane

Run commands from the repository root. For Core, <TypeName> is the Swift type name:

```sh
swift test --package-path Packages/Core --filter <TypeName>
```

SwiftPM's --filter matches type names, not @Suite display names. For example, use
PersistenceTests, not the text passed to @Suite.

For one functional App suite, use the concrete simulator:

```sh
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'platform=iOS Simulator,name=Whirr Test iPhone 17' \
  -only-testing:WhirrTests/<Suite> \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test
```

SwiftPM's --filter does not apply to xcodebuild; App narrowing uses
-only-testing:WhirrTests/<Suite>. The performance bundle uses the same concrete destination and
-only-testing:WhirrPerformanceTests/<Suite>.

`-parallel-testing-enabled NO` is part of the shape, not a local convenience. CI runs the App lane
the same way for a measured reason: Swift Testing's default
in-process parallelism admits the whole target at once, and the waiting tests then poll on the
1ms schedule faster than the cooperative pool can service them. Keep the flag on a whole-target
local run as well, so a local green and a CI green describe the same execution. The merge gate
passes it on every App `test-without-building` lane, including the real-time one. Narrowing with `-only-testing` changes which suites run, not this shape.

`.serialized` is not a substitute for the flag or for the key-window gate. It orders cases within
one suite only; the key window and `PlayerLayoutProbe` are process-wide, so hosted-layout suites
share them through `KeyWindowGate` (`App/WhirrTests/KeyWindowFixture.swift`). Do not add or drop
`.serialized` to "fix" cross-suite interference: either the suite hosts the key window and uses the
gate, or it does not and the trait is unnecessary.

## Building to run the app by hand

The gate and test commands pass `CODE_SIGNING_ALLOWED=NO`. Never use it for a build someone will
sign in on: an unsigned simulator build carries no entitlements, so every Keychain write fails with
`errSecMissingEntitlement` (-34018) and setup stops at "This copy of the app can't use the device
keychain". Build without the override; the project signs simulator builds locally
(`CODE_SIGN_IDENTITY = -`), which embeds the entitlements:

```sh
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'platform=iOS Simulator,name=Whirr Test iPhone 17' \
  build
```

The next test run rebuilds the same products unsigned, so rebuild this way before running by hand
again. `codesign -d --entitlements` reports nothing on a simulator build even when it is correct;
simulator entitlements live in the binary's `__TEXT,__entitlements` section.

## Rendered simulator acceptance

`Scripts/acceptance/README.md` (private tooling, not part of the public source) documents the
opt-in standalone XCTest runner for synthetic rendered journeys on dedicated iPhone/iPad simulators.
It uses the existing packaging without a new Xcode target or dependency, and saves
screenshots/trees with its assertions. It currently covers Library filter round-trips, landscape reachability, maximum-text
item-detail reachability, maximum-text Downloads clipping, podcast list identity, reader control identity/activation, Search keyboard
dismissal and queue loading-shell dismissal. The explicit `live-player` mode reuses an authorized
test-account login to check real player gestures, queue dismissal and adaptive reachability.
The explicit `offline-player` mode checks recovery of the player presentation after an undownloaded
queued start fails with its test server stopped; see the runner README for required account state.
Live result attachments contain private library metadata and must remain local or be sanitized.
These checks supplement the App suite; they do not replace physical/archive acceptance
or VoiceOver evidence. The initial evidence and limitations are in a private release record.

## Serverless UI harness

`WHIRR_UI_HARNESS=1` with `WHIRR_UI_HARNESS_SCREEN=<screen>` presents one app screen with no server,
no account and no real audio. It is
`#if DEBUG || PERF_INVESTIGATION`-only: `WhirrApp` swaps it for `RootGate` in that gate and Release
compiles every `App/Whirr/UIHarness*.swift` file out.

- `UIHarnessScenario` resolves the launch environment once per read: the screen, the pinned
  appearance (captures are reproducible, `WHIRR_UI_HARNESS_SCHEME=light` flips it) and the detail
  item. The remaining `WHIRR_UI_HARNESS_*` names stay on `UIHarness` and the per-screen scenario
  enums, which is what schemes and screenshot scripts pass.
- `UIHarnessSession` holds one `RootComposition`, built by the same initializer `AppRuntime`'s
  factory calls, against an in-memory database and a temporary support directory. It is the setup
  composition, because the harness has no account; nothing reaches the user's database, keychain
  items or downloads. The simulated audio stack (`HarnessAudioEngine`) is the harness's own, so
  transport behaviour is deterministic.
- One `UIHarness+<Screen>.swift` per screen holds that screen's fixture reads and the models it
  presents. A screen that has no production graph to consume — a signed-out state, server-owned
  search results, an EPUB that only exists on a device — keeps a scenario fake, with a comment
  saying why. Today that is `detail`, `storage`, `search`, `podcasts`, `library`, `home`, `reader`,
  the episode and detail cards, and both contextual offers; `home-settings` needs nothing beyond a
  `NavigationStack`, and the player keeps its simulated `AudioEngine` by design.

`ReflowTests`, `ReaderPageAccessibilityTests`, `AccessibilityTreeDiagnostic` and
`ReaderUIHarnessConfigurationTests` host it. They are the acceptance for any harness change: if a
fixture swap changes copy or layout and one of them fails, fix the harness, not the suite.
`UIHarnessReleaseExclusionTests` scans every app source for the harness entry points outside the
gate and checks each harness file is gated. Confirm the Release exclusion itself with:

```sh
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'platform=iOS Simulator,name=Whirr Test iPhone 17' \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Merge gate

A change lands only when all of these pass on the tree that will land:

```sh
Scripts/check-format.sh
Scripts/check-source-rules.py
swift test --package-path Packages/Core
Scripts/watch-regressions/check.sh
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'platform=iOS Simulator,name=Whirr Test iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'platform=iOS Simulator,name=Whirr Test iPhone 17' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building
```

`build-for-testing` compiles `App/WhirrTests` but never runs it; `test-without-building` is the
step that makes the App suite a merge condition. Both use one concrete destination, so the test
step reuses the build instead of recompiling for a different simulator.

The private tree runs these one at a time behind a machine-wide build lock, with a no-output
watchdog on every step, because it is developed on a 16 GB MacBook Air where two concurrent suites
starve each other and flake. That tooling is not published. On a larger machine the commands run
as shown.

This file covers how to narrow a run while working, what a failure means, and the suites that
supplement the gate rather than replace it.

## Failure taxonomy

| Classification | Meaning, recognition, and response |
|---|---|
| productAssertion | Wrong product behavior; assertion text in first failure; fix product. |
| productCrash | Product crashed or got a signal; crash or Fatal error: text; triage crash. |
| harnessTimeout | Harness stalled or hit a limit; timeout text or no summary; fix harness. |
| simulator | No usable simulator; boot, device, runtime, or simctl text; repair the lane. |
| toolchain | Build setup failed; compile, manifest, dependency, or stdlib text; repair setup. |
| runner | Runner failed; non-zero with no parsed failure or stronger class; diagnose runner. |
| incomplete | Result is untrustworthy; missing or contradictory fields; repair result path. |

No-pass-on-retry is a standing rule: only a positively classified pre-test runner setup failure may
be retried, and both attempts are retained. A passing retry does not erase the first failure.

### Known framework diagnostics on a green run

A green run may still print framework noise. Each such line is classified here, so that anything
*not* on this list is treated as unexplained and investigated rather than tolerated.

- **`NSURLStorageURLCacheDB _setDBSchema: ... pragma auto vacuum - disk I/O error. ErrCode: 10`**,
  emitted once by `ABSApiTests` during `CoverImageClientTests`. Cause:
  `CoverImageClient.clearCachedArtwork()` deletes the cache directory's contents and then constructs
  a replacement `URLCache` over that same directory while the outgoing instance still holds the
  unlinked `Cache.db` open. It is a product code path, not a fixture artifact, and reaches the
  device whenever a directory-backed cover cache is cleared. It is benign — the replacement recreates
  its schema on first use — and the test asserts the clear worked. **Removing it is a production
  change and needs owner approval**; until then this entry is what makes it explained.

## Waiting for something in a test

There is one waiter, `Packages/Core/Sources/TestSupport/WaitUntil.swift`. The App test target links
the `TestSupport` product (and is the only target allowed to: the source rule
`testsupport-links-only-into-whirrtests` holds that), so Core and App tests call the same functions.

| Use | Call |
|---|---|
| Wait for a state to arrive | `awaitCondition("what you are waiting for", observing: { ... }, until: { ... })` |
| Assert that something did *not* happen | `awaitQuiescence("what should have settled", of: { ... })` |
| Legacy boolean shorthand | `waitUntil("label") { ... }` |

Three rules hold for all of them.

**They are progress-bounded, not wall-clock-bounded.** `timeout` is a floor on *serviced* polling.
A `Date` deadline keeps ticking while the cooperative pool is saturated, so wall-clock waiters
expired without their condition ever being given a chance to run. Do not add a wall-clock ceiling;
the outer bound is the suite's own `.timeLimit`, which works because these unwind on cancellation.

**Give every wait a real label and, where there is a counter or a collection worth reporting, an
`observing:` closure.** The label and the observed state are what appear in the failure. A wait
labelled `"condition"` that expires tells the next reader nothing; the flake in
`CoverCacheAllCoordinatorTests` was diagnosed in one run once its wait reported
`calls 8, events 16`, and had been unreadable for as long as it said only that it timed out.

**Quiescence is a bound, not a proof.** `awaitQuiescence` returns once its signal has reported the
same value for `stableFor` consecutive serviced 1ms polls -- serviced polls, not `Task.yield()`,
because yields cost nothing and several of them elapse between two steps of the work being waited
on. Where a fake can *acknowledge* the work it did, wait on that acknowledgement instead; quiescence
is the fallback for when nothing causal is observable.

Never write a new waiting loop by hand. A `for _ in 0..<100 { await Task.yield() }` is
`awaitCondition` without the diagnostic: when the condition never holds it falls out silently and
the *next* assertion fails with a message about the wrong thing.

**This rule is machine-enforced.** `WaiterPatternTests` scans the whole test corpus for the four
shapes that defeat the waiters -- `try? await Task.sleep`, a loop around `Task.yield()`,
`DispatchSemaphore`, and a locally redeclared waiter whose body never reaches a shared one -- and
names the file and line of each. It also scans the Watch host regressions in
`Scripts/watch-regressions`, which run in the merge gate as standalone programs and so cannot call the
shared waiters: they wait through `HostWaiting.swift` there, a bounded copy that stops the program
with its label and observed state. Sites that must stay live in
`WaiterPatternScan.documentedExceptions` with the reason they stay, and the size of that list is
pinned, so it cannot grow without someone deciding to grow it. If the scan flags a wait you believe
is correct, the reason belongs in that list, not in a broader pattern.

The same scan keeps the suite fast. A new fixed `try await Task.sleep` fails it: the sites that
predate the rule are counted per file in `WaiterPatternScan.fixedSleepBaseline`, which may only
fall, and a fake that hangs until cancelled says so on one line
(`do { try await Task.sleep(for: .seconds(60)) } catch {}`). A `ContinuousClock` measurement fails
it outside an opt-in benchmark (`WHIRR_BENCHMARKS=1`), and so does a presentation, push or scroll
animated in real time: a file that animates speeds its window's layer, as the player morph suites
do with `PlayerMorphFixture.windowSpeed`, because each real-time animation holds the process-wide
key window that every hosted-window suite queues for.

Where a test needs the nth occurrence of something rather than a condition, use
`TestSupport.TestCountRecorder` instead of a private counting actor. It is bounded the same way and
reports the count it actually saw; four suites had each grown an unbounded copy, and a count that
never arrived hung the run with nothing said about how far it got.

## On-disk database cap

Every test that opens a real on-disk `AppDatabase` goes through
`TestSupport.withOnDiskDatabases` (or `SuiteOnDiskDatabases` where the store outlives a single
call). The fixture bounds how many on-disk `DatabasePool`s exist in the process at once, because
each one owns a writer queue plus a pool of reader queues and GRDB reaches them through
`dispatch_sync` — enough of them and the Swift cooperative pool has no thread left to service the
test that is waiting.

The cap is `4`, chosen by measurement rather than taste. On the historical measurement run, sweeping
`WHIRR_TEST_ONDISK_SCOPE_LIMIT` over the then-current full Core suite (4,370 tests in 370 suites,
quiet machine, one run each) produced:

| Limit | Duration | Result |
|---|---|---|
| 1 | 79.7s | 17 failures — over-serialization starves waiters in its own way |
| 2 | 31.7s | green |
| **4** | **30.5s** | **green (default)** |
| 6 | 32.1s | green |
| 8 | 32.6s | green |
| 12 | 32.6s | green |
| 16 | 32.8s | green |
| 32 | 39.7s | 2 failures — pool starvation returns |

The safe band is 2–16 and it is flat inside it, so the default sits near the fast end with room on
both sides. Override it for a one-off experiment:

```sh
WHIRR_TEST_ONDISK_SCOPE_LIMIT=8 swift test --package-path Packages/Core
```

Raising it past 16 or dropping it to 1 reproduces the failure the fixture exists to remove. If a
new suite needs a higher cap, that is evidence the suite holds too many pools open, not that the
cap is wrong.

### Seeded on-disk stores

`OnDiskDatabaseScope.open` clones a fresh store from a template migrated once per process
(`OnDiskDatabaseTemplate`) instead of replaying every migration, which costs a fresh store about
150–250 ms of CPU. A path that already holds a file is reopened as it is, so crash-recovery
reopens are unchanged. A test whose subject is the migrate-from-empty bootstrap itself, such as
`AppDatabaseTests`, passes `seeding: .migrateFromEmpty`. A harness that opens `AppDatabase.onDisk`
directly calls `OnDiskDatabaseTemplate.seedIfAbsent(at:)` first. `WHIRR_TEST_ONDISK_SEEDING=off`
switches seeding off for the whole process, to measure one binary both ways. The measurements are
in a private plan.

## Source rules

A test that only asks "does this text appear in that file" is a source rule, not a Swift test. Rules
live in `Scripts/source-rules/`, one TOML file per area, and `Scripts/check-source-rules.py` checks
the whole tree in about three seconds. It runs in the merge gate and on every push in the CI Format
job. The script's header documents every field; the short version:

| Field | Meaning |
|---|---|
| `id`, `why` | A kebab-case name, and the sentence printed on failure: what breaks if the pattern spreads |
| `files`, `exclude` | Globs the rule reads; each must match at least one file |
| `forbid` | A Python regex that must not appear |
| `allow`, `at_most` | The files that may keep it, and how many matches each file may have |
| `text` | `code` (comments blanked, the default), `code-no-strings`, or `raw` |
| `example`, `ok` | Snippets that must match and must not match, so the regex is tested |

Write a rule when the property is a ban ("nothing outside X calls Y", "no screen draws a material
behind a badge") or an allowlist. Keep a Swift scan on `ViewSourceScan` only when the property
needs structure that a regex cannot express: an ordering between two calls, the body of one
function, or a count that has to match between two files. Write a behaviour test when the value
can be computed: a copy string, a summary, a redaction set. Do not pin the presence of code
("this view calls `foo`"). If it matters, test the behaviour `foo` produces. If it only matters
that nothing else replaces it, write the ban.

Like `ViewSourceScan`, the lint fails closed. A glob that matches nothing, an `allow` entry whose
file no longer contains a match, an `example` that does not match, or an `ok` snippet that does
are all reported as broken rules, never as a pass. Both strippers share one lexer design: Swift's
and Python's agree on every App source.

To check that a new rule bites, add the forbidden line to a file in its scope, run
`Scripts/check-source-rules.py --rule <id>`, and revert. `--list` prints every rule id.

## CI lanes

CI runs on the private repository; its workflows and helper scripts are not published.

CI runs four independent jobs, each with its own time budget, so a slow or hung lane cannot push
another past its deadline:

| Job | Budget | What it proves | Blocking |
|---|---|---|---|
| Format | 10 min | `Scripts/check-format.sh` is clean and the source rules pass | yes |
| Core package tests | 25 min | `swift test --package-path Packages/Core` | yes |
| App tests | 40 min | `build-for-testing` then `test-without-building` on `iPhone 17` | yes |
| Memory measurements | 30 min | `WhirrPerformance` on `iPhone 17` | no — advisory |

The App job compiles once, on the same concrete destination it then tests against. The previous
single-job workflow built for `generic/platform=iOS Simulator` and tested on `iPhone 17`, so the
test step recompiled everything. The generic-destination Release build is a release-gate obligation
(R1.3), not a per-PR one, and is exercised there.

Build reuse is only safe because `ViewSourceScan` now fails closed. It resolves its root from a
compile-time `#filePath`; a bundle executed away from the checkout that built it used to enumerate
nothing and pass. Do not enable cross-runner sharding or cache restore at a different path without
re-reading that guarantee.

Every lane runs `Scripts/ci-select-xcode.sh` first, and the two simulator lanes then run
`Scripts/ci-simulator-preflight.sh`. Both are separately named steps that emit
`::error title=Infrastructure::…`, so "the runner could not give us a toolchain or a simulator" is
visibly a different failure from an assertion or a timeout. The preflight also writes
`simulator-preflight.json` with `"classification": "simulator"` next to the other artifacts.

## CI artifacts

Each lane uploads, under `<lane>-<run_id>-<run_attempt>`, retained 14 days:

- the raw build and test logs;
- `<lane>-report.json`, the classified summary from `Scripts/test-report.py`;
- the `.xcresult` bundle, for the App and performance lanes;
- `simulator-preflight.json`, and on failure a `simulator-diagnostics/` directory holding
  `simctl` device and runtime listings plus CoreSimulator and crash logs.

The classify and upload steps run under `if: always()`. That covers a superseded run as well as a
failing one: `concurrency.cancel-in-progress` is on, and `always()` still executes during the
runner's cancellation grace period, so a cancelled lane publishes what it had already produced.

Reading a failure starts with `<lane>-report.json`, not the log: it carries the classification from
the taxonomy above, the first-failure signature, and per-test durations. The log is for when the
classification is `runner` or `incomplete`.

## Inventory and report commands

The static inventory scans Swift sources without building or running tests. Its lines values are
raw line counts, including comments; declaration and risk counts exclude // comment-only lines.

```sh
Scripts/test-inventory.sh
Scripts/test-inventory.sh -o /tmp/whirr-test-inventory.json
```

Normalise a SwiftPM console log or an Xcode result bundle with the same record shape:

```sh
Scripts/test-report.py --swift-log /tmp/swift-test.log --label core
Scripts/test-report.py --xcresult /tmp/Whirr.xcresult --label app \
  -o /tmp/whirr-app-report.json
```

A run with no terminal run-summary record is incomplete and exits non-zero. Such a run is
classified by reading its last forty lines: `toolchain` if it never compiled, `productCrash` if it
died, `harnessTimeout` otherwise -- a crash and a hang must not look alike to a reader. `xcrun` is
required for `--xcresult`; an unavailable `xcrun` is an explicit error, never an invented result.

The classifier's taxonomy is pinned by its own self-test, which runs in the format lane:

```sh
Scripts/test-report-selftest.py
```

It asserts that a deliberately failing test, a crashing test, a timed-out waiter, and a failed
simulator step are classified correctly *and* differently from one another, that a green run is
`ok`, and that a waiter's serviced-poll diagnostic survives into the report rather than being
replaced by a bare "Test x failed" line. Add a case to it before changing any pattern in
`test-report.py`; three of the four defects it first caught were silent, and one of them had been
reporting every green Core run as a harness timeout.

## Every implementation report records

- commit and dirty-worktree state;
- selected Xcode/Swift versions and simulator runtime;
- exact command/lane and cold versus warm state;
- test count, duration distribution, result bundle, and first failure signature;
- whether concurrency, order, cache, or host load was varied;
- any skipped, expected-issue, or device-only row;
- redacted diagnostics only—never credentials, server URLs, item/session IDs, or payloads.

A command killed because it exceeds a local watchdog is recorded as a failure with the last known
phase. It is not reported as “tests unavailable” or omitted from the run count.
