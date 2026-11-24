# API conventions

This is the binding request-policy contract for Audiobookshelf traffic. Endpoint evidence lives in
the API research brief and the live-server notes (`research/audiobookshelf-api.md` and
`research/live-server-notes.md`, private records). Keep historical investigation there and
normative behavior here.

Supported floor: Audiobookshelf **2.35.1**. It is the fixture/source baseline, not the first release
with every required API capability. Supporting an older version requires version-specific fixtures
and an architecture decision.

## Authentication

1. Login with `POST /login` and `x-return-tokens: true`. Store access and refresh tokens in
   Keychain; never store the password.
1a. Single sign-on uses ABS's mobile OIDC flow with Whirr's own PKCE pair and client `state`
    (OIDC plan OI.1). First leg: `GET /auth/openid` with `response_type=code`,
    `redirect_uri=whirr://oauth`, `code_challenge`, `code_challenge_method=S256` and `state`. The
    server answers `302` to the identity provider and sets `connect.sid` and `auth_method`; Whirr
    keeps those cookies and opens the identity provider's page in `ASWebAuthenticationSession`.
    `400 Invalid redirect_uri` means the administrator has not listed `whirr://oauth` in Allowed
    Mobile Redirect URIs. Second leg: once the callback's `state` matches, `GET
    /auth/openid/callback` with `code`, `state` and `code_verifier`, replaying the first leg's
    cookies, returns the same user and token payload as `POST /login`. `400 No session` means the
    server no longer holds the attempt; a `302` to `/login?error=…`, or a callback without a code
    (`code=undefined`), is a refusal. The resulting pair refreshes exactly as a password login's.
1b. **The one transport exception.** The shared URL sessions keep `httpCookieStorage = nil`, and
    no other endpoint sees a cookie. Only the OIDC endpoint opts a request into surfacing a `3xx`
    unfollowed and returning its `Set-Cookie` values as typed cookies, held in that attempt's
    memory alone. A proxy `Cookie` custom header is merged into the
    replay; a name collision with a server cookie is refused rather than guessed.
2. Authenticate requests only with `Authorization: Bearer <accessToken>`. Tokens never appear in a
   query string. Current cover/image endpoints are unauthenticated.
3. The foreground authenticated transport refreshes through `POST /auth/refresh` with
   `x-refresh-token`, proactively five minutes before a valid JWT `exp` or reactively after 401. JWT
   claims schedule refresh; they do not establish trust. Persist rotated tokens atomically before
   releasing waiters.
3a. Refresh failure preserves credentials and local data. Transport, cancellation, 429, 5xx,
    unexpected status, malformed 2xx, and 403 retain tokens and their distinct error category. A
    refresh 401 or a resource request still returning 401 after its single retry enters
    `reauthenticationRequired`; it is not logout. A transport failure also schedules the bounded
    same-token retry in 3c.
3b. Initial background-download request minting stamps the stored access token without a proactive
    refresh. A transfer 401 may request one forced renewal. Only a renewal the server answers with
    `401` becomes durable `pausedAuth`; every other renewal failure stays an ordinarily retryable
    transfer failure.
3c. A refresh that fails in transport (a timeout or dropped connection) has an unknown outcome:
    ABS saves the rotated pair before writing its response, then accepts the old refresh token
    only for its grace period (`REFRESH_TOKEN_GRACE_PERIOD`, ten minutes by default) and returns
    the current pair for it. The client therefore waits 60 seconds for a refresh response, and
    after a transport failure retries the same refresh token after waits of 5 s, 30 s, 2 min and
    5 min (about 7.6 minutes in all), without waiting for another request or for the admission
    backoff. Any successful refresh, a definitive
    rejection (4a), replacement tokens or logout ends the schedule; a failure inside it never
    starts another. A server that answered (any status) is not an unknown outcome.
4. Refresh is global and single-flight. Concurrent callers await the same operation, then each
   original request retries at most once through the normal request gate.
4a. Definitive rejection latches `reauthenticationRequired` for that live account. Further
    foreground authenticated sends and forced renewals fail locally until successful same-account
    re-authentication atomically replaces the tokens. Initial transfer minting can still stamp one
    stored stale token before the task pauses. A relaunch may attempt one fresh refresh.
5. Explicit logout attempts `POST /logout` with the refresh token, then wipes local credentials even
   if the server request fails. A re-authentication refused because the server returned a different
   user also attempts `POST /logout`, best-effort, with that user's new refresh token; nothing
   local is touched either way.
5a. The login route is server-rate-limited. Back off after the first failure and never automatically
    retry rejected credentials.

## Progress and playback sessions

6. Online playback uses `POST /api/items/{id}/play[/{episodeId}]`, repeated
   `POST /api/session/{id}/sync`, and `POST /api/session/{id}/close`. This is the online path that
   records listening time.
6a. A successful play response supplies the only permitted network playback resources. Whirr
    currently requests `forceDirectPlay: true`; direct-play tracks resolve to authenticated
    `/api/items/{id}/file/{ino}` URLs. The server can describe transcoded playback as
    `/hls/{sessionId}/output.m3u8` with `playMethod: 2`, but Whirr does not support the server's
    Socket.IO `stream_reset` lifecycle, so `PlaybackSessionCoordinator` refuses any response whose
    `playMethod` is non-zero or whose tracks carry an HLS playlist, closing the just-opened server
    session as compensation. Persist a returned session ID immediately.
    Confirm an individual session with
    `GET /api/session/{id}`; no server-wide open-session list is a correctness dependency.
6b. AVFoundation playback does not bypass the one-retry auth boundary. For one playback attempt,
    an authentication failure may trigger exactly one authorization renewal, resource
    reconfiguration, and reload. Ignore stale/non-auth failures and stop after a second consecutive
    auth failure; never create an engine-owned refresh loop.
7. Sync every 15 seconds while playing, or every 60 seconds in Low Power Mode or on a
   constrained/cellular connection. Also sync immediately on pause, completed seek, backgrounding,
   item switch, and close. An open ebook writes its latest position at most every 15
   seconds, and on backgrounding and close; each write requests a drain, and backgrounding waits
   for that drain under a bounded background task.
7a. Audio backgrounded while `.playing` keeps its session open and the normal/degraded cadence
    running. Backgrounding triggers an immediate sync, not a close. A buffering session stays open
    and receives that immediate sync but has no periodic cadence until playing resumes. Close when
    playback ends or is displaced.
7b. Schedule the next periodic deadline before awaiting the current drain. Missed deadlines
    coalesce behind an in-flight drain; recovery sends one catch-up request, not one per missed
    interval. The ±2-second cadence check excludes intervals spanning a path change or system timer
    suspension and records those intervals separately.
8. A sync body contains `{ currentTime, timeListened }`, where `timeListened` is the delta since the
   last acknowledged sync. Reset the accumulator only after endpoint-specific success.
9. Persist `closePending` before attempting close on stop, item switch, termination, or suspension
   without active playback. Use a bounded background task and reconcile on next launch. iOS has no
   guaranteed termination callback.
10. Offline playback records stable client-UUID local sessions and uploads them in bounded
    `POST /api/session/local-all` batches. Never concurrently replay the same session; clear only
    result rows explicitly marked successful.
11. One-shot progress and finished changes use `PATCH /api/me/progress/{libraryItemId}` (or the
    episode/batch variant). Never include an `id` field in a progress payload. A reset deletes the
    row by its server id (`DELETE /api/me/progress/{progressId}`, id resolved by
    `GET /api/me/progress/{libraryItemId}[/{episodeId}]`), matching the stock clients, and
    restores a surviving other-medium position with a field-scoped PATCH.
11a. While a downloaded item plays locally, mirror its latest position through the one-shot PATCH,
     coalesced to one unsent row per item/episode identity. Omit `isFinished` unless a genuine
     transition sets it to `true`; an explicit `false` could reopen server progress. Listening time
     remains in the local-session batch. Taking the server side of a conflict discards the unsent
     mirror in the same transaction.
11b. Progress PATCHes are field-scoped: omit untouched fields rather than sending `null`. An ebook
     position sends `ebookProgress` and, only when Readium supplies a complete bounded
     `epubcfi(...)`, an `ebookLocation`; it never sends `currentTime` or `id`. Ebook completion is
     its own `{ "isFinished": true }` operation, and the server holds one item-wide finish flag.
12. Apply [SYNC-SPEC.md](SYNC-SPEC.md) conflict rules: acknowledged server timestamps are
    authoritative, local timestamps are monotonic and skew-clamped, non-trivial progress is
    protected from zero-like overwrites, and ties are deterministic.

## Request discipline

13. Caps are independent: four foreground API requests, six coalesced ABS cover requests, two
    background transfers, four RSS feed requests, and two RSS artwork requests. The deliberate
    aggregate managed-pool limit is 18 while RSS is composed; it is not a global connection cap,
    and playback transport is outside it. RSS artwork never consumes ABS cover slots.
14. Retry with exponential jittered backoff (base one second, cap five minutes), reset on success.
    Never use a fixed-interval retry loop.
15. Library traversal is paginated at roughly 50–100 minified items per page. Fetch expanded detail
    on demand and use the batch endpoint for bulk item detail; never walk a large library
    unpaginated.
15a. Smart Lists need every episode of the Audiobookshelf shows a list names. That expansion (`SmartListShowExpansion`) uses `POST /api/items/batch/get`, chunked by the shows' stored episode counts (at most 2,000 episodes and 10 shows per chunk, halving on a size refusal down to one show), then one per-show expanded fetch per show, in sequence. Only that per-show fetch records a complete episode list or proves absence; a batch response never soft-deletes. It runs within rule 13's cap, rule 14's per-show backoff and the background pass's deadline.
16. Build local search indexes/metadata incrementally from paginated sync, never as a synchronous
    launch-time full-library sweep.
17. Server-expensive operations such as a library scan are user-initiated only.
18. Request covers at an appropriate quantized display width and format and coalesce identical
    work. The live server exposed no validators, so the current client uses a disposable
    client-managed cache and does not implement Cache-Control/ETag/Last-Modified revalidation.
    That cache is a file store, one file per item, width, format and revision (`CoverFileStore`),
    swept of old revisions and removed items after each finished cover pass and once a day.
    Covers are revision-addressed instead: an item cover request carries `ts=<server updatedAt in
    epoch ms>`, so a replaced cover is a new URL and cache entry. The item-detail cover alone is
    not quantized once its shape is known: it is requested at the exact width that shape draws
    (`DetailArtworkSizing`), never wider than the quantized width it replaces. The server's own resized-cover
    cache ignores `ts` and is not purged by a rescan, so a width it cached before the replacement
    stays stale until the cover is re-set through ABS
    (private plan `plans/abs-cover-revision-plan.md`).
    The format is `webp` everywhere except the Watch's own cover client, which asks for `jpeg`
    because watchOS cannot decode WebP.
19. Client-side restraint is mandatory even if a route appears unthrottled. Treat any 429 as real;
    reverse proxies and login throttling may still reject abusive traffic.

## Refresh and compatibility

20. Foreground and explicit pull refresh are correctness paths. Explicit refresh is never
    throttled: the user asked, so the catalogue is walked however recently it was last walked.
    Foreground refresh is a correctness path for **server progress**, which it applies on every
    delivery; its *catalogue traversal* is subject to a minimum interval per library
    (`SyncEngine.minimumForegroundTraversalInterval`), so catalogue metadata may be up to one
    interval stale. Foreground delivery is frequent and uncorrelated with server change — an
    `.active → .inactive → .active` bounce emits one, and 140 of 196 measured consecutive
    foreground intervals were under a minute — so treating every delivery as a full traversal was
    cost without freshness. System-scheduled podcast refresh is opportunistic and system-budgeted.
    Per-library shelf responses are limited, but the complete post-pass is bounded by a whole-pass
    deadline that cancels its in-flight work. No fixed background timer, persistent poller, or
    Socket.IO connection may become a correctness dependency without a new ADR.
21. Decode optional fields leniently and apply the admission/selected-field bounds plus structural
    requirements in `ARCHITECTURE.md` §7. Top-level corruption is `.decoding`, not an offline state.
    Foreground API responses use the route-proportionate transport admission in `HTTPTypes` and
    selected fields/collections apply their route-specific bounds; streaming media, background
    files, and covers use their separate admission paths. There is deliberately no fictitious
    universal field limit. B8 is closed by focused decode/cover regressions and an end-to-end
    `URLSessionHTTPClient` undeclared-length streaming-cap regression; it has no separate physical-
    device row in the known-issues list.
22. When behavior is ambiguous, verify against supported server source or the supervised live
    instance and record the evidence in research. Do not guess from stale published API docs.
23. Read `serverVersion` from pre-login `GET /status`, record it during setup/smoke runs, and reject
    versions below 2.35.1 with an upgrade message. Changing the tested floor requires refreshed
    fixtures and release-note/source review. Establish identity before version: the same response
    must decode as JSON carrying `app == "audiobookshelf"` (case-insensitive), and anything else —
    a foreign `app`, an absent one, or a body that is not JSON at all — is refused as not an
    Audiobookshelf server rather than reported as unreachable or out of date. `/status` is the only
    evidence setup has before it sends credentials, so an address that merely answers must not
    reach the login POST. The same check is the first gate for a new address of an existing
    account (Settings › Server & Account › Server addresses); the second is `GET /api/me` through
    that address with the stored access token, which must name the account's own user id before
    the address is stored. Endpoint selection at launch, foreground, and reconnect probes every
    stored address with `/status` concurrently, takes the most-preferred answer inside a
    two-second window and the first answer after it, and stops waiting once it has a winner.
    Background refresh never probes; it uses the stored active address.

## Downloads and podcasts

24. Audio uses per-file `GET /api/items/{id}/file/{fileid}/download`; EPUB uses
    `GET /api/items/{id}/ebook`. Transfers run in a background `URLSession`, which owns ordinary
    background/network resumption. Whirr deliberately does **not** persist or reconstruct manual
    byte-range resume data. Launch reconciliation reattaches a surviving system task; if none
    exists, it reconciles state and restarts from byte zero. The whole-item zip endpoint is not used.
24a. An advertised `ebookFormat` is not sufficient to download. Expanded detail must supply a
     non-empty `ebookFile` inode, an EPUB extension, and a positive expected size; otherwise fail
     closed rather than requesting bytes.
24b. Ebook delivery uses `POST /api/emails/send-ebook-to-device` with only `libraryItemId` and
     `deviceName`, and only on an explicit user action. The device list comes from
     `POST /api/authorize`'s `ereaderDevices`, read lazily and cached per account for ten minutes
     or until a device-not-found response. Only device names cross `ABSApi`; device email addresses
     are never persisted, logged, or displayed. The server sends synchronously and without
     idempotency, so the request carries a 120-second timeout, is never retried automatically (rule
     4's single post-401 resend excepted), and a timeout, lost connection, or 5xx is reported as
     uncertain rather than failed.
25. Run at most two file transfers. Cellular or constrained-network downloads require the user's
    opt-in.
25a. Manual pause/resume must continue one existing background task or enqueue one replacement—never
     both. A row whose adapter task is only suspended is resumed; one whose task is gone (failed,
     interrupted) restarts through the ordinary scheduler. Either way it consumes a transfer slot.
26. Audiobookshelf owns podcast feeds, checks, retention, and server-side episode downloads. Whirr
    reads the server library and may display those settings read-only for diagnosis; it does not
    perform feed administration or broad server-podcast administration. Two narrow exceptions
    exist: NP12's, next, and the automation-settings write of ADR 0017, after it. The NP12
    exception ([ADR 0006](adr/0006-save-native-podcast-episodes-to-audiobookshelf.md), accepted
    2026-09-01) permits only explicit, user-initiated save/remove for one episode, and only when
    the shared account capability admits a live, active `admin`/`root` account plus
    `permissions.update` for Save or `permissions.delete` for Remove:
    - `POST /api/podcasts` only to create a missing show in a validated podcast library/folder;
      that new-show payload may include only the followed feed's eligible declared artwork URL,
      while missing/rejected artwork is omitted and existing-show/enqueue payloads remain image-free;
    - `POST /api/podcasts/:id/download-episodes` with exactly one validated stored native RSS
      episode; and
    - `DELETE /api/podcasts/:id/episode/:episodeId?hard=1` only for a confirmed episode whose
      complete preflight proved it absent before this attempt.
    This exception must be carried only by the bounded, account-scoped `SyncEngine` coordinator.
    AppModel passes an opaque native feed/episode identity and destination choice; the
    Persistence-backed command reader validates the current subscription, an absolute HTTP(S)
    enclosure without embedded credentials, private-feed ineligibility, and any optional artwork
    independently (including host, userinfo, fragment, bounds, and literal-address policy); only then may
    `SyncEngine` construct the bounded `ABSApi` request. Raw third-party enclosure URLs and
    credentials never become AppModel state or logs. Durable attempt transitions, including the
    account fence, are committed before the next network step; accepted/uncertain responses
    reconcile before an explicit retry, and no automatic mutation retry is added (rule 4's one
    resend after a definitive 401 remains transport policy). A server 403 remains authoritative.
    The NP12 exception does not authorize feed checks, queue control/clear, scans, retention or
    auto-download changes (those belong to ADR 0017 alone), show edit/delete, pre-existing episode removal, arbitrary URL/path
    input, ordinary-user writes, private feeds, or any other server-podcast administration. It
    adds no timer, poller, socket, or pool/reachability composition; ADR 0004's direct RSS-origin
    classes and isolated pools remain unchanged. The optional artwork causes one ABS-server-side
    fetch only during new-show creation; Whirr exports no feed credential/header with it and the
    Audiobookshelf administrator's DNS/redirect/egress policy remains authoritative. The
    v2.35.1/v2.36.0 SCP.0 matrix must stay green for direct, redirected, and rebound private targets.
    The second exception
    ([ADR 0017](adr/0017-edit-server-podcast-automation-settings.md), accepted 2026-11-11) permits
    an explicit change to one server show's automation settings, only for an account the shared
    capability admits as live, active `admin`/`root` with `permissions.update`:
    - `PATCH /api/items/:id/media` whose body carries only `autoDownloadEpisodes`,
      `autoDownloadSchedule` (one of Whirr's preset cron expressions),
      `maxNewEpisodesToDownload` and `maxEpisodesToKeep` (bounded integers validated by
      `ABSApi`; the new-episode limit is never sent as `0`, which the server treats as no limit).
    That route is the server's general item-media edit and admits any account with `update`, so
    the closed request encoder and the client capability are the boundary: no metadata, tags,
    cover URL or `lastEpisodeCheck` is ever sent. The write is carried by an account-checked
    `SyncEngine` service, not the NP12 coordinator. It is online-only, never queued and never
    retried automatically (rule 4's resend excepted); a server 403 remains authoritative and
    invalidates the cached capability. The one write the user does not set directly is turning
    automatic downloads on for a show that **Save Show to Audiobookshelf** has just created. This
    exception does not authorize feed checks, queue control/clear, scans, show metadata edit or
    delete, ordinary-user writes or private feeds, and adds no timer, poller or socket.
    Native RSS subscriptions contact RSS origins
    only within the bounded scope of [ADR 0004](adr/0004-native-rss-podcast-subscriptions.md) and
    only through the feed policy below. Device auto-download is separate: it uses rule 24 only
    for episode files already stored by the server, as recorded in
    [ADR 0002](adr/0002-device-podcast-auto-download.md).
27. RSS feed fetch uses the `PodcastFeeds` client pool: its own request gate (cap 4), per-URL
    coalescing, 10 MiB body cap, redacting logging, and backoff pacing. Conditional GET replays
    persisted validators, and a 304 short-circuits before HTTP-status error mapping. Redirects
    follow `FeedRedirectPolicy` (at most five hops, cross-origin permitted, HTTPS-to-HTTP downgrade
    rejected, and `Authorization` stripped on cross-origin hops); ABS traffic keeps
    `ABSRedirectPolicy` unchanged. The pool is never composed with
    `ReachabilityObservingHTTPClient`: feed-host failures must not assert an ABS outage, and ABS
    reachability never gates feed traffic. Feed URLs are absolute HTTP(S) without embedded
    credentials, and no RSS request carries ABS credentials. Enclosure and directory-search policy
    remain bounded by ADR 0004 and their implementation checkpoints.
28. RSS artwork uses a separate source-specific request pool capped at two, with a separate cache
    and identity namespace from ABS covers. Eligible URLs are only show artwork explicitly declared
    by a followed feed and iTunes thumbnails returned by directory search. Identity is source + feed
    identity + normalized artwork URL, where a directory result's provider identity supplies the
    pre-follow feed identity. A URL or `ETag`/`Last-Modified` validator change refreshes the entry;
    without validators the existing entry is periodically revalidated rather than given a new
    identity on each feed refresh. Feed credentials are attached only for an artwork URL on the
    feed's exact origin. Redirects are bounded, strip `Authorization` on a cross-origin hop, and
    reject https→http downgrade; directory thumbnails never receive feed credentials. The existing
    cover byte and image-MIME admission rules apply unchanged.
