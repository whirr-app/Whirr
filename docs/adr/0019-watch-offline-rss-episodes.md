# ADR 0019: Watch copies of native RSS episodes, sent by the iPhone

- Status: **Accepted** (2026-11-20). Submitted the same day together with
  the plan, whose owner decisions WRS-OD1–OD9 the owner
  accepted at the recommended defaults. Accepting this ADR is what authorises the
  structural parts: the new `WatchPlayback` stores, the `Persistence` migration, and the
  amendments listed under Consequences.
- Date: 2026-11-20
- Superseded in part: Decisions 1 and 6 by
  [ADR 0020](0020-watch-fetches-rss-episodes-and-reports-status.md) (2026-11-21). The Watch
  downloads the episode itself; `transferFile` is not used. Decisions 2–5 stand.

## Context

Native RSS subscriptions are device-owned and play on the iPhone only
([ADR 0004](0004-native-rss-podcast-subscriptions.md)). The Watch refuses those episodes in four
places, and `WatchABSSelection` exists so that no handoff can imply Watch-local RSS playback. The
Watch companion plan deferred Watch-owned native-feed downloads behind an owner decision and an
ADR covering credentials, retention, identity and conflict
(risks R11–R13 in that plan).

The owner wants an RSS episode downloaded on the iPhone to be listenable on the Watch with the
phone away, and accepts that the iPhone initiates it. A fully native RSS stack on the Watch was
considered and deferred: the Watch's 2 GB budget holds about 25 episodes whatever it follows, so
independent subscriptions buy browsing rather than listening capacity, and they would add GRDB,
CloudKit entitlements and a refresh model to the Watch before that model has any evidence.

## Decision

1. **The iPhone may send a downloaded native-RSS episode's audio to the Watch.** The transport is
   `WCSession.transferFile` for audio and `transferUserInfo` for an offer and an inventory. The
   Watch stores it in new `WatchPlayback` types, not in the ABS download store, whose manifest,
   quota and scheduler are account- and server-shaped.
2. **Ownership is split and explicit.** The phone owns the desired set (`rssWatchCopy`, a
   device-owned table). The Watch owns its inventory and is authoritative about what it holds.
   Delivery is acknowledged by the inventory; a completed transfer is not "On Watch".
3. **Playability is derived on the Watch.** A `.nativeFeed` episode plays on the Watch when a
   complete received copy exists. The wire still never claims Watch playability for an RSS row, so
   the validators stay. This amends the invariant stated in `WatchHandoffValues.swift:10-13` and
   `WatchProtocol.swift:188-190` as it applies to the playing report: that report may name an RSS
   episode so the phone can avoid a concurrent start. Handoff and pending progress remain
   ABS-only.
4. **The phone remains the only writer of RSS episode state.** A Watch listen is applied through
   the phone's existing writer, with the Watch's listen time, exactly as a listen on the phone.
   No new iCloud field, no second writer, no per-episode schema change. `lastListenedAt` is not
   added: a phone-local value would be lost on the next remote apply, and a synced one is a
   permanent Production field.
5. **Watch copies are fenced by the Watch's own Audiobookshelf account stamp for this version.**
   Signing out on the Watch clears them and the phone re-sends after sign-in. This is a deliberate,
   recorded exception to ADR 0004's "surviving logout" sentence: that sentence governs the phone's
   device-owned data, and a Watch copy is a re-sendable cache. They share the 2 GB Watch budget,
   are backup-excluded, and use `completeUntilFirstUserAuthentication`.
6. **No RSS-origin traffic is added.** No feed credential, enclosure URL or server write crosses to
   the Watch. ADR 0004's four traffic classes and its prohibitions stand unchanged.

**Out of scope.** The Watch fetching enclosures itself (a fifth, Watch-origin traffic class under
ADR 0004) is the next milestone and needs its own amendment. Subscriptions, feed refresh or a
second RSS state store on the Watch are not planned (owner, 2026-11-20); reopening them needs a new
decision and ADR.

## Consequences

- New `WatchPlayback` types: a received-episode store with tombstones and reservations, a native
  progress journal, and an inventory planner. These cross a layer boundary and need this ADR's
  approval, not a per-file judgement.
- `Persistence` gains `rssWatchCopy` at migration v104, plus the prune-history and reaper
  exemptions. The table is excluded from iCloud sync and from `.whirrpodcasts.json` backups.
- The Watch app gains a `didReceiveUserInfo` path and an audio file ingress.
- Documentation to amend in the same change: `watch-companion-plan.md:131-134` and R11–R13;
  `watch-podcast-sources-plan.md:127`; the comments cited in Decision 3; SECURITY and the privacy
  policy gain the Watch-side location and lifetime of a copy. ARCHITECTURE needs no dependency
  change.
- Protocol version stays 1. Every addition is a new key or an optional field; an older peer
  ignores it, and an older Watch makes the send time out with copy telling the listener to update
  the Watch app.
- The Watch app has no test target, so pure rules live in `WatchPlayback` and the wiring is
  verified on devices.

## Alternatives

- **The Watch fetches the enclosure itself.** Better on transfer speed and independence, but it
  needs a fifth ADR 0004 traffic class, an enclosure URL or opaque token on the wire, a
  private-feed credential decision, and it accepts that dynamic ad insertion makes the Watch's
  bytes differ from the phone's. Deferred as the next milestone, not rejected.
- **Fully native RSS on the Watch.** Not planned (owner, 2026-11-20). Podcast CloudKit sync would
  carry episode state to the Watch as a third device, but not the episode catalogue, the audio or
  feed credentials, so it still needs feed fetch, GRDB, a watchOS refresh model, a CloudKit adapter
  and entitlements on the Watch. What it adds over this decision plus automatic sending — episodes
  published after leaving the phone — needs a Watch with its own connection. Ad skip, transcripts
  and Up Next order would not carry over.
- **Save to Audiobookshelf, then download as an ABS item.** Works today for server administrators
  with public feeds, but splits progress from the native copy and adds server library content
  (ADR 0006). Not the feature.
