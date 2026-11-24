# Security

Scope: a personal-use app talking to a self-hosted Audiobookshelf server, usually over Tailscale or
LAN. Where a separately approved build enables native RSS, it also contacts the bounded feed,
enclosure, and artwork origins defined by ADR 0004. The tailnet shrinks the Audiobookshelf exposure
surface; it does not remove the need for sound defaults.

## Threat model (what we defend against)

| Threat | Stance |
|---|---|
| Token/credential theft from a lost or backed-up device | Keychain-only storage, no tokens in files/UserDefaults/logs |
| Traffic interception on hostile networks | TLS by default; plain HTTP only for deliberately configured private servers, where the WireGuard tunnel or trusted LAN is the transport protection |
| A malicious/compromised *server* sending hostile payloads | Route-proportionate streaming response admission, selected field bounds, and a separate cover byte/MIME gate constrain ordinary API and artwork payloads. EPUB renders as sandboxed Readium/WebKit content rather than native plugin loading; external links are scheme-allowlisted and confirmed, and archive/message controls are bounded at their input seams |
| A hostile RSS feed, enclosure, or artwork origin | Untrusted XML may attempt entity expansion, oversized documents, or malformed encodings; bounded Foundation `XMLParser` depth/item/string caps (an oversized item `content:encoded` or channel `<language>` is dropped rather than failing the feed; every other oversized retained string fails it, while content the parser never retains, such as unused attribute values, namespace URIs, comments and processing instructions, is ignored rather than checked), transport byte limits, redirect policies, and the cover byte/MIME gate constrain those inputs, lying enclosure metadata, and image payloads |
| A feed-controlled URL causing an unsafe NP12 server-side fetch or credential disclosure | The accepted NP12 path uses only the stored enclosure and, on new-show creation only, eligible declared artwork of a subscribed, non-credentialed native feed. Both require bounded absolute HTTP(S) values without userinfo; artwork additionally rejects fragments, NULs, localhost, and literal non-public addresses. The app accepts no arbitrary URL/path input, keeps raw URLs below AppModel, and lets only an account-fenced SyncEngine coordinator construct the bounded ABSApi mutation. Feed credentials, ABS tokens, cookies, and custom headers never accompany either server-side fetch. Audiobookshelf's DNS/redirect/egress policy remains an explicit trust boundary; the live v2.35.1/v2.36.0 SCP.0 gate proves direct, redirected, and rebound private artwork targets are blocked on supported versions |
| Supply-chain risk in dependencies | Minimal pinned dependency set; exact-version pins; review on bump |
| Data leakage to third parties | Zero analytics/telemetry/crash SDKs; app-owned networking targets the configured ABS server, plus only ADR 0004's bounded RSS destinations when that separate feature is enabled. A publication URL reaches `UIApplication` only after Whirr's explicit scheme allowlist and reader confirmation; all other schemes are refused. The one fixed outbound first-party link is Settings › About › Report a Problem's GitHub issue URL, user-tapped, carrying version strings only |

Out of scope: multi-user hostile-tenant scenarios and DRM. TestFlight signing, privacy manifests, export-compliance declarations, and third-party attribution remain in scope even for personal distribution.

## Transport

1. **HTTPS by default.** Setup UI defaults new server URLs to `https://`; reaching a server over HTTP requires the user to type that scheme deliberately. Only `http`/`https` schemes are accepted (`ABSServerConfig`).
2. **Project/release guidance:** Tailscale's built-in HTTPS certificates (`tailscale cert` /
   Synology package equivalent) give a publicly valid certificate for the `*.ts.net` hostname that
   works everywhere the tailnet does. This recommendation is recorded here for deployment and
   release preparation; it is not presented as an in-app Settings help feature.
3. **Plain-HTTP servers are supported** (user decision 2026-07-21; T0.7 found the real server HTTP-only, and most home ABS instances are). The honest trade-off: bearer tokens and media travel unencrypted on that route, so the protection is the network itself (WireGuard tunnel or trusted LAN). Setup and Settings do not display an HTTP warning (user decision 2026-09-06). Single sign-on is the exception: it is never offered or started over plain HTTP (user decision 2026-11-19), because an on-path attacker could swap the identity provider's page for a fake and collect a password that reaches far beyond this server. `ABSClient.beginOIDCLogin` refuses a non-HTTPS server before sending anything, and setup hides the button. ATS consequence: the app target sets `NSAllowsArbitraryLoads` (T0.3), because per-domain exceptions cannot cover arbitrary user-typed hostnames and `NSAllowsLocalNetworking` misses tailnet MagicDNS names (ATS already exempts raw IP literals). Publication resources remain local; user-activated external EPUB links follow rule 11's confirmation and scheme-allowlist policy.
4. Certificate handling: system trust only. No `ServerTrust` bypass code paths, no "accept any cert" toggle — those become permanent holes.

## Credentials & tokens

5. Access + refresh tokens in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (background audio/downloads need post-boot access; `ThisDeviceOnly` keeps them out of iCloud/desktop backups). The add query states `kSecAttrSynchronizable: false` explicitly rather than relying on the platform default; lookup/update/delete queries use `kSecAttrSynchronizableAny`, so rule 8's wipe cannot miss a synchronizable entry left by a migration or an older build. There is no per-item sync/backup knob — the policy is hardcoded in the queries and asserted against them. Tokens are keyed by the account's credential namespace (`account:<clientUUID>`), not by the server URL, so every address of one server shares one token pair; the App's entry points migrate a legacy URL-keyed pair by copy, verify, delete. Proxy headers stay keyed per endpoint URL and are never sent to another address. Proving that a new address is the same server sends the stored access token as a plain bearer to `GET /api/me` through that address only; a token refresh is never performed through a candidate address, so a stranger cannot be handed a fresh pair.
6. The password itself is never persisted — used once for `POST /login`, then discarded. Single sign-on (OIDC plan OI.1–OI.3) runs the identity provider's page in `ASWebAuthenticationSession`, so Whirr never sees IdP credentials. The PKCE verifier, the client `state`, the authorization `code` and the server's per-attempt cookies (`connect.sid`, `auth_method`) live only in memory inside one `OIDCAttempt`: single use, bound to the server that began it, abandoned on every path that does not complete it, and never logged, persisted, or included in diagnostics (its descriptions are redacted). The attempt's cookie jar is its own; the shared URL sessions keep `httpCookieStorage = nil`. Setup and Watch setup use an ephemeral browser session; same-account recovery shares Safari's, and the same-user check (rule 8a) refuses a different user without mutation.
7. Tokens never appear in: logs, error messages, URLs (Bearer header only), crash output, or exported diagnostics. A redaction helper in ABSApi formats requests for logging with the auth header stripped — using it is mandatory, enforced by convention + test. `HTTPRequest` itself hand-writes `description`/`debugDescription` so that reflecting *any* request — not just the two wrapper types that remembered to — cannot print the `Authorization` header or the URL. The problem-report bundle Settings › About › Report a Problem writes is an exported diagnostic under this rule: its inputs are the closed-enum diagnostics store, the current process's log for Whirr's subsystem, and locally stored MetricKit payloads, and `ProblemReportRedaction` drops any line naming the account's server address or user id before the file exists. `ProblemReportComposerTests` feeds those terms through every input and asserts the output carries none of them.
8. Logout and user switching require explicit confirmation, cancel transfers, close or persist
   pending sessions, then wipe Keychain entries, the account-scoped database, downloaded media,
   cover cache, exported diagnostics, and the widget files (rule 21). A server-logout failure is non-blocking only after verified
   local cleanup has completed without retaining credentials. Every thrown error before that point,
   including credential-clear, purge, deletion, or verification failure, blocks the flow
   and remains retryable. Adding or switching between addresses of the same server is not a
   switch in this sense: it keeps every local item and is admitted only by the proof in
   API-CONVENTIONS.md rule 23.
8a. **Automatic session rejection is not logout.** A failed or rejected token refresh — transport failure, rate limit, server failure, malformed response, or a definitive 401 — must never clear Keychain entries, delete account-owned database rows or downloaded media, or return the app to first-time setup (API-CONVENTIONS.md rules 3a/4a). The app enters a non-destructive **re-authentication required** state over the normal shell: completed downloads stay playable, durable local progress capture continues, and same-server/same-user re-authentication replaces the token pair in place. Only the explicit confirmed flow in rule 8 deletes local account data; re-authenticating as a *different* user is refused without local mutation and routed to that explicit flow. The server session that refused sign-in opened for the other user is revoked best-effort (`POST /logout` with its own refresh token) rather than left valid until it expires; an API token is that user's own key and is not revoked.
8b. B7's release-candidate implementation now serializes removal as single-flight; drains foreground
    sync by awaiting `SyncEngine.shutdown()` after playback is quiesced and before the purge and the
    credential wipe, so a traversal in flight at removal ends with valid credentials before its
    account row is deleted (the account foreign-key cascade still refuses any later write); binds
    each account-lifetime `ABSClient` to its account at construction, so a client that outlives
    removal refuses every other account locally with `APIError.cancelled` before reading Keychain,
    and can neither send nor refresh a later account's credentials against the removed account's
    server and proxy headers; does not let a token refresh that completes after the Keychain wipe
    re-save the cleared pair (the check is not atomic with the store, so removal's post-read remains
    the final check); fences account intents in DownloadCoordinator and treats required purge
    failure as blocking; verifies token and custom header removal by post-read; unconditionally
    clears playback artwork; deletes and verifies the palette cache; keeps covers in a disposable
    file store under Caches, in a directory named by a hash of the account scope; drains and terminally fences cover fetches before removing the cache
    directory; and re-admits cached cover bytes through MIME/size policy. Historical gate totals and
    output belong in the dated release evidence, not this contract. B7 remains open until the
    current candidate's gates and the physical-device pass covers logout while transfers are active
    or suspended (including user-paused and Wi-Fi-held work), relaunch attachment, and the resulting
    lock-screen, Now Playing, and remote-command state. Those rows live in LOGIN-SEC-21 and the
    release-device backlog.
8c. Future private-feed credentials live in their own Keychain store and use a feed-owned header
    type with the same CRLF/token-name validation. ABS credentials never accompany RSS requests.
    When implemented, feed credentials may be sent to artwork only when its URL has the feed's
    exact origin. Artwork redirects are bounded; cross-origin redirects strip `Authorization`, and
    https→http downgrade is rejected. Directory thumbnails never receive feed credentials.

## App & data hygiene

9. Local database and downloaded media live in the app container with iOS file protection `completeUntilFirstUserAuthentication`; downloads are excluded from iCloud backup (`isExcludedFromBackup`) — they're re-fetchable and large.
10. The `whirr` scheme has two uses. The single-sign-on callback (`whirr://oauth`, decided 2026-11-06) is accepted solely as an `ASWebAuthenticationSession` callback: the session matches its scheme itself and returns the callback to the attempt that started it, and a callback is used only if its `state` matches that attempt. Widget and Live Activity taps (decided 2026-11-06, WTD-OD1 in the tap destinations plan) need the scheme registered in `CFBundleURLTypes`, so any app or web page can now open a `whirr://` link. The app's one URL handler, `RootView.onOpenURL`, accepts only the five `whirr://widget/…` forms that `WidgetTapDestination` parses strictly (an item by its opaque token, the player, the Stats screen, Latest Episodes, a smart list by its positive local row id) and ignores every other URL, `whirr://oauth` included, without logging it. An accepted link only navigates: a token resolves through the account-stamped token map (rule 21) or to nothing, and no link plays, changes, deletes, or reveals anything, or starts a request. The worst a hostile link can do is open the player, Stats, Latest Episodes, one of the listener's own smart lists (a guessable local id, which opens only a list the app last published for the signed-in account and otherwise goes nowhere), or the card of a title already on the listener's own widget shelf or smart list widget, whose salted token is not readable outside the App Group. Any future deep link or App Intent validates parameters against local database identities and never uses them to construct a request directly.
10a. Current Siri/App Shortcut metadata is generic and contains no title, author, account, server,
    or library value. Voice actions accept only direction or a finite sleep-timer choice, resolve
    resume/skip against the validated local playback bookmark, and reach the server only through the
    ordinary account-scoped playback-session path. The weak intent bridge is unavailable before
    sign-in and is rebound or cleared on every account lifecycle transition.
11. **Implemented in phase 6, with explicit limits.** EPUB content is untrusted input:
    `ReadiumEPUBRenderer` accepts only an existing local file URL, delegates parsing/rendering to
    Readium/WebKit, does not start or own the deprecated external GCD web server, and shuts down
    through explicit `close`/`stop` operations. Tests cover bounded locator translation with text
    context dropped, the complete-CFI gate, open-failure classification, and lifecycle/metadata
    translation. Internal links stay in the publication; `http`, `https`, `mailto`, and `tel` links
    require a confirmation that displays a sanitized, bounded destination; script,
    data, file, and custom schemes are refused before `UIApplication.open`. The pure policy and the
    delegate wiring are covered by `ReadiumEPUBRendererTests`. DRM is out of scope.
    Expanded-resource admission is implemented: `EPUBArchiveAdmission` bounds entry count, per-entry
    and total expanded bytes, and per-entry compression ratio from the archive directory, before any
    entry is decompressed; a refusal surfaces as `.unopenable` and traces only the failing
    measurement. Values crossing the WebKit/Readium seam are bounded where they arrive rather than
    only where they are persisted: `ReadingPosition.validated` voids a position whose href exceeds
    the shared string bound, `validatedEPUBCFI` drops an oversized CFI, and table-of-contents
    flattening bounds nesting depth, entry count, and title length. **The admission limit values
    are provisional** pending calibration against a real library; the mechanism, not the constant,
    is what R1 required.
11a. Companion PDFs (pdf-supplements-plan.md) are untrusted server content under the same rule.
    `SupplementPDFView` opens only a local file URL; PDFKit runs no document scripts; links inside
    the document navigate in place, and every URL link goes through `ReaderLinkPolicy` with the
    same confirmation and scheme refusal as rule 11. The viewer's share button is the one
    user-initiated export of downloaded server content: it hands the reader's own local PDF to the
    system share sheet only when they tap it, and nothing is exported, uploaded, or logged
    otherwise. Filenames, page numbers, and `ino` values are not logged.
12. Dependency policy: exact-version pins, both committed `Package.resolved` files, and deliberate reviewed bumps—never drive-by. The reviewed production/test graph, licence texts, and privacy behavior are recorded in the release dependency inventory. No analytics, tracking, or third-party crash SDK is linked.
13. B8's code scope is discharged with route-proportionate admission. Ordinary foreground API
    requests default to a 25 MiB transport cap: `URLSession.bytes(for:)` is admitted first by
    `Content-Length` when supplied and then by a bounded byte accumulator, before complete response
    materialisation or JSON decode. Selected fields and collections additionally use the bounded
    decoding helpers appropriate to their routes rather than a false universal field limit. Cover
    requests have their own 20 MiB transport/body cap and reject missing or non-image MIME types
    before caching. Streaming media and background downloads intentionally use file/streaming paths
    instead of that in-memory API budget; status and final size are validated, and MIME is checked
    when the server supplies it, before playability. A real `URLSessionHTTPClient.send` regression
    with an undeclared-length, multi-chunk custom-protocol body proves the streaming accumulator
    rejects the first byte beyond its cap before full materialisation, and a sibling rejects an
    over-cap declared `Content-Length` (`HTTPTypesTests.streamedBodyWithoutContentLengthEnforcesRequestCap`,
    `declaredContentLengthOverRequestCapIsRejected`). There is deliberately no JSON nesting-depth
    bound on server or database decodes (owner decision 2026-11-19, audit 2026-11 P0-8): the body
    cap bounds the input and the platform decoder's own depth handling is accepted; only the
    hostile backup file carries a depth pre-scan. B8 is closed and has no separate device
    row.
14. Database, outbox, and downloaded-file creation must set `completeUntilFirstUserAuthentication`. Tests inspect real resource values for the database and the ad-skip/transcript roots; downloaded-file stores pin only that protection is requested and that a file which cannot be protected is removed fail-closed, because the simulator does not implement Data Protection (owner decision 2026-11-19, audit 2026-11 P0-5). A downloaded file is moved into place before protection is applied, so an interrupted completion briefly holds the platform default class, which is already `completeUntilFirstUserAuthentication`. Re-fetchable downloads and cover caches are excluded from backup, while the small database remains backed up so local progress is not silently lost. On the Watch, account-linked state (the account record, setup receipt, phone catalogue cache, download labels and resume bookmark) is written only through `WatchProtectedFileStore`: protected until first unlock, excluded from backup, and never in `UserDefaults`, whose plist the Watch backs up to the paired iPhone. What stays in `UserDefaults` is deliberate: the random device ID, the pending-progress sequence counter, and the browse sort and filter preferences, whose keys carry the account hash and server library or show IDs but no URL, username or title.
14a. **Watch copies of native-RSS episodes.** [ADR 0020](adr/0020-watch-fetches-rss-episodes-and-reports-status.md)
    supersedes [ADR 0019](adr/0019-watch-offline-rss-episodes.md) in part. The Watch downloads the
    enclosure itself, in its own background `URLSession`, from the URL the iPhone's offer names; the
    phone never downloads the file for it. A copy exists only after the Watch admits that download,
    moves the file into its received-episode store through the reservation taken at offer time, and
    reports it in its inventory. This is ADR 0004's fifth traffic class, Watch-origin enclosure
    fetch.
    - **No credential reaches the Watch.** Only non-credentialed feeds are offered
      (`App/Whirr/Watch/WatchEpisodeSendPublisher.swift`), so no feed credential,
      `Authorization` header or cookie reaches or leaves it. The Watch's RSS session keeps no
      cookies, response cache or credential storage
      (`App/WhirrWatch Watch App/WatchRSSDownloadURLSessionAdapter.swift`), and its
      requests carry no header of any kind
      (`App/WhirrWatch Watch App/WatchRSSDownloadDriver.swift`). No feed fetch, preview,
      artwork fetch or directory search originates on the Watch.
    - **Redirects are judged after completion, hop by hop.** A background session follows redirects
      itself, so `FeedRedirectPolicy` cannot run per hop. The Watch reads each transaction's URL
      from `URLSessionTaskMetrics`: an `http` hop may upgrade to `https`, any `http` hop after an
      `https` one rejects the chain, every hop must be `http`/`https` with a host and no embedded
      credentials, and missing metrics are a rejection
      (`Packages/Core/Sources/WatchPlayback/WatchEnclosureRedirectCheck.swift`). Bytes from a
      rejected chain are discarded and never stored or played
      (`App/WhirrWatch Watch App/WatchRSSDownloadDriver+Completion.swift`). ATS does not
      supply this rule, because the Watch app allows arbitrary loads for self-hosted
      Audiobookshelf.
    - **Success, size and space.** Only 200 and 206 complete a copy, and a 206 counts only when its
      `Content-Range` total is the whole file that arrived. The bytes are validated against the
      1 GiB cap and the final response's own length, never the feed's declared length, because
      inserted ads change it (`Packages/Core/Sources/WatchPlayback/WatchEnclosureResponseCheck.swift`;
      cap, `Packages/Core/Sources/WatchProtocol/WatchEpisodeSend.swift`), and an overrun is
      cancelled in flight (`App/WhirrWatch Watch App/WatchRSSDownloadDriver.swift`). The
      reservation is the declared length plus 10% (at least 1 MiB), or the whole 1 GiB cap when the
      length is unknown, clamped to the cap
      (`Packages/Core/Sources/WatchPlayback/WatchEnclosureAdmission.swift`); it is claimed at
      offer time against the shared 2 GB Watch budget
      (`Packages/Core/Sources/WatchPlayback/WatchStorageBudget.swift`) and shrinks to the file's
      size on completion. The Watch never reads free disk space
      (`Packages/Core/Tests/AppModelTests/ReleaseAuditTests.swift`).
    - **Storage.** The file lives inside the Watch app's container under Application Support, in the
      signed-in account's directory, never in Caches; it has file protection
      `completeUntilFirstUserAuthentication`, is excluded from backup, and counts against that same
      2 GB budget with Audiobookshelf downloads
      (`App/WhirrWatch Watch App/WatchSessionController.swift` and `:274`,
      `Packages/Core/Sources/WatchPlayback/WatchDownloadFileVault.swift` and `:199-205`). It
      is removed when it finishes playing unless the listener's setting keeps played copies,
      removed on either device, or cleared when the listener signs out of Whirr on the Watch; a copy
      is re-sendable, and the phone offers it again after sign-in.
    - **The status report.** The Watch's `WatchStatusReport` — its account stamp, link health, the
      time it last checked its server, and its capabilities — travels only in the WatchConnectivity
      application context between the paired devices (ADR 0020 Decision 6). It starts no request
      and stays on those devices. On the phone, `rssWatchCopy` and `rssWatchCopySet` are
      device-owned and excluded from iCloud sync and from `.whirrpodcasts.json` backups. The
      Watch's last download report is kept for the phone's next launch in `UserDefaults`
      (`App/Whirr/Watch/WatchDownloadStatusRecord.swift`); it holds only local episode row ids,
      revisions, the four in-progress states and progress values — no title, URL or account data —
      and is read only for the Watch install that reported it.
14b. **Audiobookshelf books and episodes sent from the iPhone.**
    [ADR 0021](adr/0021-iphone-sends-audiobookshelf-items-to-the-watch.md) extends 14a's desired set
    to Audiobookshelf titles without a new credential path.
    - **The offer names titles, never files.** `WatchABSSendOffer` carries the item and episode IDs,
      a revision, a title and subtitle the wire validates (no control characters, nothing that reads
      as a URL or path, at most 512 bytes) and a declared size. No URL, token, cookie or file list
      leaves the phone (`App/Whirr/Watch/ABSWatchSendPublisher.swift`). The Watch plans and
      downloads the audio itself with its own Audiobookshelf sign-in, exactly as a download started
      on the wrist does, so rule 13's token handling is unchanged.
    - **Every offer is account-fenced.** It carries the phone's authenticated account stamp, and the
      Watch acts only on an offer that matches its own signed-in account
      (`Packages/Core/Sources/WatchPlayback/WatchABSRequestLedger.swift`). The phone reads the
      Watch's Audiobookshelf entries only when they are stamped with its account, and sends nothing
      for an account until such an inventory has arrived (WSA-OD11), so a sign-in to another
      account never removes the first account's copies by omission.
    - **Storage.** On the Watch the pending offer and the account's request ledger are written with
      protection until first unlock and excluded from backup; the ledger sits under the account's
      directory and both go at sign-out with the account's downloads
      (`App/WhirrWatch Watch App/WatchABSRequestDriver.swift`,
      `App/WhirrWatch Watch App/WatchSessionController.swift`). On the phone, `absWatchCopy` is
      account-owned: it cascades from `account`, so signing out deletes it, and a schema trigger
      forgets the inventory's account in the same transaction. It is excluded from iCloud sync and
      from podcast backups. The Watch's last Audiobookshelf report is kept for the phone's next
      launch in `UserDefaults` (`App/Whirr/Watch/ABSWatchInventoryRecord.swift`) with server item
      and episode IDs, revisions, states and progress values but no title, URL or credential; it is
      scoped to one Watch install and account, and cleared at the account boundary.
15. **EPUB evidence and calibration.** Rule 11 is the current implementation contract. The
    admission mechanism and content-seam bounds are release controls; their values remain
    provisional until a representative-library calibration establishes otherwise. Device/archive
    acceptance verifies the behavior without re-opening the already-implemented control boundary.
15a. Audiobookshelf returns each e-reader device's email address alongside its name. `ABSApi`
     decodes the name only, so addresses never reach memory beyond the response body, persistence,
     logs, diagnostics, or the UI. A send failure's server text can name SMTP hosts and is matched
     against fixed strings only, never carried or displayed.
16. iCloud key-value storage receives only the tested allowlist of app-wide, non-sensitive
     `UserDefaults` preferences. Server URLs, account identity, credentials and tokens, database
     state, diagnostics, transient view/reader state, and downloaded media never enter that store.
    The IC0.2 capability spike is DEBUG-only: its approved Development signing may use the private
    `iCloud.com.remoteconcern.whirr` CloudKit container, `aps-environment` `development`, and shared
    remote notifications for synthetic encrypted `PodcastStateProbe` data. Since 2026-11-08
    (ADR 0009 TestFlight amendment) Release, the TestFlight build, uses the same container in the
    Production environment with `aps-environment` `production`, while Debug stays in Development;
    real podcast state syncs only after device-local consent.
    CloudKit podcast sync consent is device-local and default-off: `PodcastCloudSyncConsentStore`
    keeps the flag in `UserDefaults` bound to a random install token held in a
    `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable Keychain item, so a
    restored or migrated installation reads no consent. Neither key is in the KVS allowlist
    (`ICloudSettingsSyncTests` pins this). Every synced record field except the
    integer `schema` marker is a CloudKit encrypted field (`PodcastCloudRecordLayout`, audited by
    `PodcastCloudRecordLayoutTests`); those field values become end-to-end encrypted when the user
    enables Advanced Data Protection. Record names, `schema` and CloudKit system metadata stay
    structural and are never encrypted, so the user-derived components of every record name are
    HMAC-SHA256 under a per-account random record-name key rather than bare digests of the feed
    URL and episode identity: an observer holding only the zone's names cannot recover the follow
    list from a public podcast index. The key lives in one encrypted `v1.keyring` record in the
    zone, is read before any name is derived, survives logout, and is not a Keychain item; the
    record-name amendment in the podcast data settings plan records why. Podcast sync logs carry
    failure categories, record kinds (`settings`, `state`), service error codes and counts, never
    a title, feed or enclosure URL, or payload. One exception (owner decision HRR-OD1,
    2026-11-13): when the service refuses a save as invalid, the CloudKit adapter logs the
    service's own error text, because it names the record type and field that were refused and
    nothing else does. That text can include the record's name, which is a keyed hash, and no
    field value. Disabling sync and signing out
    never delete cloud data; only the confirmed Delete Podcast Data from iCloud action deletes the
    `PodcastState` zone, and it leaves local data unchanged. Podcast backup files
    (`.whirrpodcasts.json`) are plain, unencrypted JSON written only on request to a location the
    user chooses (owner decision 2026-09-25). They carry feed addresses and listening state but
    never feed credentials: the snapshot mapping skips a credentialed feed URL and
    `PodcastStateSnapshotCodec` rejects one. Settings copy never calls a backup safe to share,
    because a private feed address can carry an access key.
17. Every RSS enclosure transfer is capped at 1 GiB regardless of its declared length (unknown
    sizes also reserve 500 MB of free disk), is cancelled on overrun, and validates completion
    against actual bytes, the cap, and the final response's own length because declared enclosure
    lengths are untrusted advisory metadata, not a checksum. RSS audio lives under the non-account `RSS/` file
    root and deliberately survives logout and account removal as device-owned data under ADR 0004.
    Device-side enclosure and artwork fetches deliberately have no localhost or private-address
    gate (owner decision 2026-11-19, audit 2026-11): self-hosted and LAN feeds are a supported use,
    and the device fetches only from feeds the user followed. The private-address refusal applies
    to NP12's server-side artwork fetch only, where the server, not the device, would make the
    request. Feed and enclosure redirects to targets carrying userinfo are rejected.
18. RSS artwork is limited to show artwork explicitly declared by a followed feed and thumbnails
    returned by iTunes directory search. HTML/page scraping, description images, arbitrary episode
    links, and unrelated third-party artwork are prohibited. Its source-specific two-request pool,
    cache, identity namespace, credentials, reachability, and outage state are isolated from ABS
    artwork. Responses pass the existing 20 MiB cover byte/body cap and image-MIME admission before
    caching or decoding.
19. **NP12's server-side save/remove boundary.** Save and remove are explicit, one-episode
    mutations visible only to an active `admin`/`root` account with the action's narrow live
    permission (`update` for Save, `delete` for Remove); the server's `403` remains authoritative.
    The only permitted routes are the ADR 0006 create-if-missing, single-episode enqueue, and
    confirmed hard-remove routes. The feature is ineligible for device-held `FeedCredential`
    feeds and for enclosures containing embedded credentials, and it accepts no user-entered URL,
    filesystem path, feed check, queue control, scan, retention/auto-download setting, show
    administration, ordinary-user write, or pre-existing episode deletion. AppModel carries only
    opaque native identities and sanitized state. The account-owned attempt stores no credentials
    or copied URL; each durable transition is committed before the next network step and the
    captured account identity is rechecked before persistence or presentation, so logout or
    account replacement cannot publish old-account results. Accepted/uncertain outcomes reconcile
    before an explicit retry; no timer, socket, independent pool, or automatic mutation retry is
    introduced. The automation-settings write is a separate boundary
    ([ADR 0017](adr/0017-edit-server-podcast-automation-settings.md)): the same account capability
    with `update`, one route, and a closed body of four fields with no URL, path, credential or
    free text. It is online-only, and the account identity is rechecked before its result is
    stored or shown. It is unavailable to device-held `FeedCredential` feeds, which cannot have a
    server copy made by Whirr.
20. **Podcast ad-skip data stays on the device.** Episode transcripts and episode audio prints are
    user content: they are files under the `AdSkip` root in Application Support, protected
    `completeUntilFirstUserAuthentication` and excluded from backup, and are never logged, put in
    diagnostics, exported or synced. An audio print is a sequence of 32-bit spectral hashes: it
    cannot be turned back into audio or words, but it identifies a recording. The database holds
    the skip ranges and the learned-ad signature store: times, probabilities, 64-bit shingle
    hashes with no transcript text, and, for each learned ad, the audio print of its range. These
    are backed up with the database, so a restored device carries an identifier for each learned
    ad's recording. The podcast backup file carries the signature store too (hashes, times and
    each learned ad's print, compressed, never transcript text or an episode's own print), so that
    file, which the listener stores where they choose, holds the same identifiers; teachers are
    named only for followed RSS shows, never for server episodes. Restoring them elsewhere is harmless: ranges for a missing download are swept,
    and a learned ad's print matches only where a downloaded episode again carries that ad. None of
    these tables is account-owned; the ad-skip coordinator follows the download tables
    continuously and deletes an episode's data when its download leaves them, whichever path
    removed it (a purge, account removal, or the launch integrity sweeps demoting a restored
    database's missing files). Transcript and audio print files no row references are swept on its
    first pass after launch. Logs carry only error type names and
    counts. Turning the setting off keeps all of it, still removed with each download; Forget
    learned ads clears the signature store.
    The listener's episode transcripts follow the same rule on a second root, `Transcripts` under
    Application Support, with the same file protection and backup exclusion. Its rows are in
    `episodeTranscript`, device-owned and not account-owned like `adSkipEpisode`; the transcript
    coordinator deletes a row and its file when the download leaves the download tables, and its
    first pass after launch sweeps files on that root that no row names. A row whose file is
    missing (after a restore, say) is deleted and the episode reads as untranscribed. Each root's
    sweep touches only its own root. Unlike ad skip's, these transcripts are shown to the listener
    in the app; they are still never logged, put in diagnostics, exported or synced.
    Look Back's text, the minutes before an audiobook's playhead transcribed on demand, is shown to
    the listener and held in memory only, for the loaded book: it is never written to either root
    or anywhere else, logged, put in diagnostics, exported or synced
    (Look Back plan §4.8).
    Ad skip reads a listener transcript for two purposes, host-read sponsor spots and the
    listener's own ad marks, and only a complete one of the file as it is now
    (`CompleteEpisodeTranscriptReading`). It reads the words in memory and keeps what it keeps for
    its own transcripts: skip ranges; mark rows (a span of times); when the listener undoes a
    range, a tombstone of 64-bit shingle hashes in the signature store; and, for a mark, a
    confirmed creative of such hashes, its times and an audio print sliced from the episode's own.
    The signature store is backed up and exported as the rest of it is. No listener transcript
    text or file name is stored, logged or exported by ad skip, and its scores are held in memory
    only.
21. **Widgets draw only what the app publishes for them.** The widget extension links
    `WidgetProtocol` and nothing else from the package: it has no network, Keychain, database or
    account access, and never fetches artwork. Its only input is the snapshot and cover files the
    app writes under the `Widgets/` folder of the `group.com.remoteconcern.whirr` App Group, never
    the container root. Those files and folders are created `completeUntilFirstUserAuthentication`
    and excluded from backup; before the first unlock the extension draws its placeholder. The
    snapshot carries no server address, credential, URL, or server or item ID. A row names its
    title by an opaque token, a salted digest that changes with each account binding, and only the
    app resolves it, through a token map in the app's own container that also records the account
    stamp: a stale or foreign token resolves to nothing and starts nothing (rule 10). Text is made
    drawable before it is written (control characters become spaces, it is cut to the byte limit,
    and anything shaped like a URL or a path is dropped), and the codec validates and bounds the
    file on both sides. Covers are small JPEGs named by a salted digest of their key. Lock Screen
    accessories and the sleep-timer Live Activity draw no title, show or cover, because they are
    visible without unlocking; Home Screen widgets mark titles and covers `privacySensitive()`.
    Stats come only from the snapshot already stored for the account; publishing never fetches
    them. Signing out writes a signed-out snapshot, deletes the covers and the token map, and
    reloads every timeline and control; account removal deletes the whole `Widgets/` folder and
    the token-map folder, including when a removal resumes after relaunch (rule 8). A tap opens
    the app through a `whirr://widget/…` link that carries only a row's opaque token or a fixed
    destination; the app resolves it as rule 10 describes, and the placeholder, signed-out and
    empty states carry no link. The smart list widget reads a second file, `smartLists.json`,
    under the same rules: the lists' local ids and names and each list's first four rows, which
    name their title by a token salted per list and resolved through the same token map. Its
    account stamp must match the snapshot's or the widget draws its placeholder; signing out
    deletes it with the covers and token map. Edit Widget offers lists from that file only, so
    choosing one reads nothing else. A list row's play button starts the list's run through the
    app's own playback, exactly as Play on the list's screen does.
