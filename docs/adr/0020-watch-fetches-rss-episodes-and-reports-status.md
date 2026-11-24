# ADR 0020: The Watch downloads native RSS episodes itself, and reports its own status

- Status: **Accepted** (2026-11-21, Rhys).
- Date: 2026-11-21
- Supersedes: [ADR 0019](0019-watch-offline-rss-episodes.md) Decisions 1 and 6. Decisions 2–5 stand.
- Amends: [ADR 0004](0004-native-rss-podcast-subscriptions.md) with a fifth traffic class (text
  under Consequences, applied to ADR 0004 on 2026-11-21).
- Plan: `watch-rss-fetch-plan.md`, revision 2. Evidence: its
  §4.2 (WRB.0 device results).

## Context

ADR 0019 had the iPhone send a downloaded RSS episode's file to the Watch with
`WCSession.transferFile`. The device pass on 2026-11-20 rejected that transport: a 41 MB episode
moved at about 0.1–0.2 MB/s, stalled at 68% once Whirr on the Watch went to the background, and
after an install nothing moved for 11 minutes until Whirr was opened on the Watch. The small
messages worked: an offer over `transferUserInfo` was acknowledged, reserved and answered with an
inventory within 6 seconds.

The WRB.0 spike (2026-11-21, Debug builds only, public episodes) had the Watch fetch the
enclosure itself with a background `URLSession`:

- 44.1 MB in 19 s with Whirr on the Watch in front; 93.6 MB in 51 s with it in the background,
  the app woken for the finish; both at once in 59 s with the app not running, watchOS having
  launched it in the background for the request. Every run was proxied through the phone, and was
  still about 20 times faster than `transferFile`.
- The redirect delegate is never called in a background session, but `URLSessionTaskMetrics`
  lists every hop's URL after completion.
- A resumed transfer finishes with HTTP 206.
- The Watch app allows arbitrary loads (`App/WhirrWatch-Watch-App-Info.plist`), so ATS does not
  stop an https→http downgrade.
- Dynamic ad insertion is real: one URL served 44,137,426 bytes to the Watch and 40,769,512 to a
  Mac the night before.
- A Watch app that has never been opened receives nothing until it is opened.

Separately, Settings → Apple Watch on the iPhone shows a mixed message. Its status comes from a
live probe sent with `sendMessage`, which only goes out while `WCSession.isReachable`, and on the
iPhone that is only true while Whirr runs on the Watch. The phone cannot wake the Watch app on
demand: a complication push needs a Whirr complication on the current face and is budgeted, and a
workout launch is not a general mechanism. So the probe usually goes unanswered, and the screen
shows a grey "Connected" with an apology. B's phone statuses ("Open Whirr on your Watch", "Update
Whirr on your Watch") need the same missing fact: what the Watch app last said about itself.

## Decision

1. **The Watch downloads a native RSS episode's audio itself.** The iPhone's offer, still sent
   over `transferUserInfo`, names the enclosure URL, its declared length and its chapters. The
   Watch downloads it with a dedicated background `URLSession` for RSS, writes it into ADR 0019's
   received-episode store through the reservation taken at offer time, and reports the outcome in
   its inventory. The phone never downloads the file for the Watch. `transferFile` is not used,
   and is not kept as a fallback. This replaces ADR 0019 Decision 1.
2. **That download is a fifth ADR 0004 traffic class, Watch-origin enclosure fetch, bounded by
   mechanism:**
   - only an enclosure URL the iPhone put in an offer, for an episode of a followed feed that the
     listener chose to send; the Watch never chooses episodes, and nothing is sent automatically;
   - private (credentialed) feeds are not offered, so no feed credential, `Authorization` header or
     cookie reaches or leaves the Watch;
   - no feed fetch, preview, artwork fetch or directory search on the Watch;
   - its own session identifier and adapter, no ABS headers, no ABS reachability state in either
     direction, as ADR 0004 requires of every RSS pool;
   - ADR 0004's size rules, adapted to the Watch: a 1 GiB cap on every transfer, cancellation on
     overrun, and validation against the bytes received and the final response's own length, never
     against the feed's declared length, because inserted ads change it. Space is bounded by the
     Watch's 2 GB budget, not by free disk space, which the Watch never reads (`ReleaseAuditTests`
     pins that). The reservation is the declared length plus the phone's headroom (10%, at least
     1 MiB), or the 1 GiB cap when the length is unknown. It shrinks to the file's size on
     completion. (Corrected 2026-11-21, the day of acceptance: the first text carried over the
     phone's 500 MB free-space margin, which the Watch has no means to apply.)
     (Amended 2026-11-22, owner-approved: two unsized episodes sent together reserved 2 × 1 GiB,
     overflowed the 2 GB and the second read "Watch storage full" beside 57.8 MB used. The phone
     now sizes an offer from its own finished copy, else the feed's length, else the duration at
     192 kbps; the Watch replaces the estimate with the response's length once the download
     starts; and a storage decline stays in the offer and is taken back by the Watch, oldest
     first, once it fits. A decline for any other reason is still final at its revision.)
   - the network the Watch already allows for Audiobookshelf downloads.

   This replaces ADR 0019 Decision 6.
3. **The class's redirect rule is applied after completion, hop by hop.** A background session
   follows redirects itself, so `FeedRedirectPolicy` cannot run per hop. Once a download
   completes, Whirr reads the task's transaction URLs from `URLSessionTaskMetrics`. If any hop is
   `http` after an earlier hop was `https`, the file is discarded and the copy fails. An enclosure
   the feed declares as `http` may upgrade to `https`, as on the phone. Bytes from a rejected
   download are never moved into the store or played. Hop count is URLSession's own limit. This is
   Whirr's own check: ATS does not provide it, because the Watch app allows arbitrary loads for
   self-hosted Audiobookshelf. If the metrics are missing, the download is treated as rejected.
4. **Success accepts 200 and 206.** A 206 counts only as the completion of a system resume, and the
   length validation in Decision 2 still applies to the whole file.
5. **Dynamic ad insertion is accepted.** The Watch's copy may differ from the phone's. Listens are
   still exchanged as positions under ADR 0019 Decision 4. When the phone holds its own copy and the
   durations differ by more than a few seconds, the phone records the difference and does nothing
   else in this version.
6. **The phone shows what the Watch last reported, with its time, rather than depending on a live
   answer.**
   - Whenever the Watch app runs, it publishes a `WatchStatusReport` to the phone through
     `updateApplicationContext`, which WatchConnectivity delivers in the background and keeps
     latest-only. That covers launch, background refresh, after its own server requests, and
     sign-in or sign-out.
   - The report carries the Watch's account stamp, its link health, the time it last checked
     with its server, and the Watch app's capabilities: at least whether it can fetch enclosures.
   - The phone keeps the last report per account, and ignores a report for another account or
     one older than the one it holds.
   - The live probe stays. When it answers, its answer refreshes the same record.
   - Settings → Apple Watch re-checks by itself when the Watch becomes reachable while the screen
     is open.
   - "Connected" is never shown without the time it was confirmed.
   - The phone's RSS statuses read the same record. "Open Whirr on your Watch" means no report has
     ever arrived from this account's Watch. "Update Whirr on your Watch" means a report arrived
     without the fetch capability.

   The application context already carries the Watch's playing report, and each update replaces
   the whole dictionary. So the Watch writes both keys through one composer, and neither can erase
   the other.
7. **Protocol version stays 1.** Every addition is a new key or an optional field. An older peer
   ignores it.

## Consequences

- **ADR 0004 gains** a dated amendment line and this paragraph after class 4:
  > 5. **Watch-origin enclosure fetch** — the Apple Watch app downloads one subscribed episode's
  >    audio from the enclosure URL in an offer the iPhone sent after the listener chose that
  >    episode, under the bounds and post-completion redirect rule of
  >    [ADR 0020](0020-watch-fetches-rss-episodes-and-reports-status.md). No credential, feed
  >    fetch, artwork or directory traffic originates on the Watch.

  The "exactly four classes" sentence becomes five. The "What remains prohibited" list gains:
  enclosure requests from the Watch that no phone offer named, and any Watch-initiated request for
  a private feed.
- **ADR 0019** gains "Superseded in part by ADR 0020 (Decisions 1 and 6)" in its status; the ADR
  index gains this row.
- **New cross-layer types:** the offer entry's enclosure fields, the inventory's `downloading`
  state and progress, and `WatchStatusReport`, all in `WatchProtocol` with Core tests.
- **On the phone,** a `WatchLinkRecord` holds the last report. It is App-only and keeps
  `WatchPhoneSetupModel` (706 lines) from growing.
- **The Watch target links `PodcastFeeds`** (WRB-OD5), for URL validation and the size rules. The
  owner made that change in Xcode on 2026-11-21, and ARCHITECTURE records it. `LayeringTests`
  checks only edges between packages, so it has nothing to record.
- **The new background session identifier** enters the release audit of background identifiers.
- **Documents to amend in the same change:**
  - SECURITY: the Watch as an RSS client, with no credentials, the redirect rule and the caps.
  - `site/privacy.html`: podcast hosts see requests from the Watch, or from the phone when it
    proxies, the same as from the phone today; a Watch copy's location and lifetime; the status
    report stays on the paired devices. Required before any release.
  - ARCHITECTURE: the Watch's dependency row.
  - `watch-rss-send-plan.md`: superseded where B changes it.
- **Dropped from A:** the phone's pin-and-send path, `transferFile` and its transfer handle, the
  delivering timeout, and the stuck-sending sweeps.
- **Verification:** the Watch app has no test target. Pure rules live in Core (`WatchPlayback`,
  `WatchProtocol`, `PodcastFeeds`) with tests. The wiring is verified on devices in WRB.8.

## Alternatives

- **Keep `transferFile` (ADR 0019).** Rejected on device evidence: about 20 times slower, and it
  stalls in the background.
- **Keep `transferFile` as a fallback.** Rejected (WRB-OD2): it doubles the delivery state machine
  to keep the path that failed.
- **The phone downloads and proxies the bytes.** That is `transferFile` again, or a local server
  on the phone. Neither beats the Watch fetching through the phone's proxied connection, which
  WRB.0 measured at about 2–3 MB/s.
- **Wake the Watch for a live status answer.** A complication push only works with a Whirr
  complication on the current face, and is budgeted. Launching a workout is not a general
  mechanism. Neither makes a live answer dependable, so the phone shows the last report instead.
- **Run `FeedRedirectPolicy` per hop with a foreground session.** That would need Whirr running on
  the Watch for the whole download, which is the failure that ruled out A.
