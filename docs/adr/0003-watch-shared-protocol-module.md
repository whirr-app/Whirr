# ADR 0003: Where phone/Watch shared code lives

- Status: Accepted for implementation on 2026-09-08 (owner requested execution of the Watch programme)
- Date: 2026-08-12

## Decision

The phone/Watch command protocol goes in a new **dependency-free leaf target `WatchProtocol`**
inside `WhirrCore`, and `Packages/Core/Package.swift` gains `.watchOS(.v26)` beside its existing
`.iOS(.v26)` and `.macOS(.v15)`.

`WatchProtocol` carries only platform-neutral values and pure logic: the versioned command, reply,
selection and snapshot types, their stable error codes, the bounded command deduplicator,
the reply gate, and destination preference policy. It has no package dependencies
and no UI, persistence, connectivity or media frameworks. The phase-1 amendment is:
**no package dependencies; system frameworks behind `#if canImport` are permitted**.
`CryptoKit` supplies the authenticated account-stamp hash. The account-stamp recipe moved here on
2026-09-08 so both devices share it.

The watchOS app target links `WatchProtocol`. It does **not** link `DesignSystem`.

## Why not the alternatives

**Widening the package platforms alone, and reusing existing targets.** Discovery established that
adding a platform to `platforms:` does not require every target to compile for watchOS — a watchOS
build compiles only the dependency closure of the products actually linked. So widening is cheap,
but it is not by itself a home for shared code: without a leaf, the Watch would have to link
`AppModel` or `PlayerCore` to reach shared types and would drag in `Persistence`, GRDB, and
`Observation` for a handful of structs.

**A separate SwiftPM package.** Stronger isolation, and it would leave `WhirrCore`'s platform
declaration untouched. Rejected for now because it needs a second Xcode package reference and its
own test and release plumbing, and because it does not help the case that actually matters later:
Phase 2 wants the Watch to link `ABSApi` itself — which lives in `WhirrCore` — rather than grow a
second API client. Once the platform list is widened for `WatchProtocol`, `ABSApi` becomes linkable
without further manifest work.

## Consequences

- The package advertises watchOS support at package level. That is an advertisement, not a promise
  that every product builds there: `DesignSystem` cannot, because SwiftUI's `Menu` is unavailable on
  watchOS and four components use it unguarded. This is acceptable precisely because the Watch UI is
  deliberately not a port of the phone UI, and no `DesignSystem` product is linked by the Watch
  target.
- watchOS 26 is chosen as the floor to match the iOS 26 deployment target and because it clears
  every availability floor discovery found in code that may later be reused: `Observation`
  (watchOS 10), `Synchronization.Mutex` in `Persistence` (watchOS 11), `URLSession.bytes`
  (watchOS 8). GRDB 7.11.1 declares watchOS 7.
- `PlayerCore.PlaybackTimeline` — import-free global↔track position mapping, already tested — stays
  where it is. If the Watch later needs it, linking `PlayerCore` costs only `Observation`. Do not
  duplicate it into `WatchProtocol`.
- Adding a target is a dependency-graph change: `Package.swift`, the `ARCHITECTURE.md` §1 table, and
  the `LayeringTests` table must move together, and that registration is orchestrator-owned rather
  than delegated.
- Linking the new product to the Xcode targets is a project-bundle change made in Xcode by Rhys.

## Evidence

The watchOS portability discovery and ABS API surface discovery notes (private records under
`research/watch-companion/`), 2026-08-12. Neither was compiled; the availability floors are SDK-interface evidence, and the first
watchOS build of `WatchProtocol` is the confirmation.

## Implementation note — 2026-09-09

`App/WatchShared` now holds `WatchOwnershipDiskJournal.swift` and `WatchPeerMessageSender.swift`,
compiled into both App targets through synchronized-group membership
(`App/Whirr.xcodeproj/project.pbxproj:211` and `:240`). This shares platform adapters without a new
package edge. `WatchProtocol` remains a package leaf (`Packages/Core/Package.swift:35`), and its
CryptoKit import is guarded (`Packages/Core/Sources/WatchProtocol/WatchProtocol.swift:3`). The Watch
also links `WatchPlayback`, whose dependencies are `ABSApi`, `PlayerCore` and `WatchProtocol`
(`Packages/Core/Package.swift:36`); the original alternatives above preserve the decision's
rationale.

## Amendment — 2026-11-17

The ownership lease is retired (Watch playback extraction plan,
WPX.4, D53). `App/WatchShared` now holds only `WatchPeerMessageSender.swift`, the bounded live
request/reply bridge, and `WatchArtworkThumbnail.swift`; the disk journal and its tests are gone.
`WatchProtocol` drops the lease, reducer, recovery, query and advertisement types and their transport
keys, and gains `WatchHandoff.swift`: the pause-and-position request and reply under the new key
`whirr.watch.handoff.v2`, the Watch's playing report, and `WatchHandoffResponder`, the answering
side's admission rules shared by both devices. The protocol version stays 1 (WPX-OD3); a snapshot
from an older phone or cache that still carries `playbackLease` decodes with the key ignored. The
module stays a dependency-free leaf.
