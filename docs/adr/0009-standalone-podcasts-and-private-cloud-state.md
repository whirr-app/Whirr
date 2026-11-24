# ADR 0009: Standalone podcasts and private CloudKit state

- Status: Accepted; delivered in part and closed by the 2026-09-25 scope amendment
- Date: 2026-09-05
- Amended: 2026-09-06 (keyed record names; see the
  record-name unlinkability amendment in the private podcast data settings plan);
  2026-09-24 (sync enabled in Release builds; see
  [Personal-distribution amendment](#personal-distribution-amendment-2026-09-24));
  2026-09-25 (standalone runtime dropped; see [Scope amendment](#scope-amendment-2026-09-25));
  2026-11-08 (Release moves to Production for TestFlight; see
  [TestFlight amendment](#testflight-amendment-2026-11-08))
- Authorization: Rhys requested implementation of revision 3 of the standalone podcast plan.

## Decision

Implement the standalone podcasts, iCloud sync, and restorable backup plan (private,
`plans/standalone-podcast-icloud-sync-backup-plan.md`).
The accepted scope is D1–D7 and the existing owner decisions OD1–OD6. Acceptance of this design
does not assert that its runtime, signed capabilities, or device verification already exist.
On 2026-09-05 Rhys approved continued implementation using selected iCloud Drive/local folders
for automatic backups, deferring automatic Synology support. Production activation remains gated
on two-device validation; implementation no longer waits on a second device. Simulator sign-in
is unavailable with the owner’s physical security-key setup and must not be requested.

Native RSS podcasts become usable without an Audiobookshelf account. GRDB remains the runtime
source of truth; an optional ABS account adds server features. Native settings, Saved for Later,
Up Next, playback bookmarks and RSS files survive ABS removal. RSS queue ordering remains local.
Separate native queue and saved tables retain source ownership without nullable account keys.

Opt-in CloudKit uses only the listener's private database in `iCloud.com.remoteconcern.whirr`,
custom zone `PodcastState`. Debug signing selects Development, Release signing selects Production;
the first Production schema deployment remains a separate owner-run action. No Whirr identity,
backend, shared/public database, or new package target is introduced. Sync absence/failure never
disables local use. Disable retains local/cloud data; zone deletion requires a separate user action.

The approved podcast data settings design (a private plan) exposes
separate iCloud Sync and Backups destinations. Sync consent is device-local and defaults off;
no CloudKit initialization, account checks or requests occur before explicit confirmation. A
one-time informational Podcasts introduction sheet explains device-local shows, server shows and
opt-in sync (Rhys, 2026-09-05); it is not a consent surface and there is no other prompt or
reminder. Automatic backups independently default off; choosing an iCloud Drive
folder never enables CloudKit sync. Portable restore imports neither consent nor folder access.
Backup UI can ship independently; production sync UI remains hidden until its runtime and
physical two-device acceptance are complete. Separately confirmed cloud deletion authorizes only
that operation when ordinary sync is off.

Sync covers native subscriptions/order, global/per-feed settings, episode state, saved membership,
and last-played reference. Every record field except a `schema` version marker is a CloudKit
encrypted field, including stamps and identifiers, so those values become end-to-end encrypted
when the listener enables Advanced Data Protection; record names, `schema` and CloudKit system
metadata stay structural, and no reference or asset fields exist. Record names are CloudKit
metadata and are never encrypted, so (amended 2026-09-06) their user-derived components are
HMAC-SHA256 under a per-account random key held in one encrypted `v1.keyring` record in the same
zone, minted through a `serverRecordChanged` race and read before any name is derived; the local
identities they are derived from stay unkeyed so snapshots and backups never wait on CloudKit.
The key is not stored in the Keychain. Downloads, caches,
notification ledgers, ABS entities, credentials and transport bookkeeping are excluded. Feed
credentials remain device-only Keychain values. Identity is versioned and deterministic, and
record names are keyed so that identity cannot be recovered from them; a durable
subscription registry and follow generations prevent stale children resurrecting an unfollow.
Episode aliases have non-sparse identity records. Active-generation deletion markers do not expire.

Episode state merges as a whole register ordered by explicit epoch and mutation stamp. A stale
playback session cannot overwrite an explicit reset by advancing its wall clock (superseded by
[ADR 0011](0011-reset-is-a-server-row-deletion.md): this device's unsent listening now beats a newer
remote reset). Mutations and
outbox generations commit atomically; an acknowledgement cannot clear newer work. Engine state,
callbacks and sends are fenced by container/environment/zone/iCloud account/epoch. Bootstrap fetches
before uploading, including after state loss. Account changes retain local data and require an
explicit merge choice before sending to the newly observed account.

Versioned bounded snapshots provide independent recovery. Restore validates before writing,
preserves omitted values and newer deletions, and applies accepted registers in one transaction.
It does not adopt an old installation identity or restore CloudKit transport state. Native saved
resolution happens before explicit restored saves. V1 backups use `.whirrpodcasts.json` with
`public.json`, without an exported UTType. Automatic rotation uses a chosen Files directory;
an app-owned iCloud Documents location is separately gated and not approved by this ADR.

## Layer ownership

`Persistence` owns tables, transaction helpers and transfer values. `SyncEngine` owns portable
state values, codec, pure merge and the cloud-sync protocol. It may depend on Persistence; the
reverse edge is prohibited. The App owns CloudKit objects, opaque system-field archiving,
CKSyncEngine delegation, Files coordination and native service lifetime. There is no
`SyncEngine → PodcastFeeds` edge and no CloudKit import in Persistence or AppModel.

The first implementation checkpoint contains host-only merge primitives and a manually invoked,
DEBUG-only synthetic CloudKit spike. Neither is composed into the production runtime. Production
contract/privacy changes and capability audit allowlists land with their corresponding runtime
and Xcode changes, so documents never claim a partially implemented standalone shell is shipped.

## Supersession and compatibility

- ADR 0004's requirement for an ABS account, exclusion of RSS state from iCloud, and deletion of
  RSS queue rows at logout are superseded for the new runtime. Its direct RSS transport,
  credential, parsing, enclosure and artwork restrictions remain unchanged. Native RSS **network**
  orchestration stays outside SyncEngine; portable cloud conflict/outbox work belongs there.
- ADR 0001's account/API background leg remains optional alongside account-independent RSS work.
  Keep the single `com.remoteconcern.whirr.podcast-refresh` identifier and existing pass budgets.
  CloudKit adds silent remote notification capability after Xcode provisioning; no polling timer.
- ADR 0002's account defaults continue to govern ABS automation. Native automation uses a separate
  device-owned defaults store and the existing native per-feed overrides.
- ADR 0006's server-copy attempts remain account-owned and clear on logout. Retaining native
  source data grants no additional server administration capability.
- Native show order remains separate from ABS custom ordering; no mixed custom show ordering.

## Acceptance

Use the plan's dependency order, deterministic matrices and four repository merge gates. The
capability spike must establish an encrypted private-zone exchange, persisted engine state, and
device Files bookmark/write/relaunch behavior. The iPhone server round trip is verified, and the
two-device round trip passed on physical iPhone and iPad in both directions on 2026-09-18. The
owner declines Simulator iCloud sign-in; Simulator compilation is not device evidence. Track outstanding physical work in the
IC0 evidence packet (a private release record); do not mark IC0 complete or enable
production sync until its required rows pass.

## Personal-distribution amendment (2026-09-24)

Rhys explicitly approved enabling iCloud podcast sync in Release builds ahead of the physical
evidence above. Whirr is installed from Xcode on his own and his family's devices, with no App
Store or TestFlight distribution planned, so every build is development-signed.

- `Whirr.entitlements` (Release) carries the same entitlements as `WhirrDebug.entitlements`: the
  private `iCloud.com.remoteconcern.whirr` container, CloudKit only, `aps-environment`
  `development`, and `icloud-container-environment` `Development`. Debug and Release share one
  Development database, and no Production schema is deployed. `ReleaseAuditTests` pins this exact
  shape for both files.
- `PodcastDataSettingsReadiness.iCloudSync` is `true`. Consent stays device-local and default-off,
  so nothing touches CloudKit until the listener enables sync.
- The remaining IC0 physical rows (relaunch state, account switch, Data Protection, provider
  revocation) remain outstanding. They are now field evidence from Rhys's devices rather
  than a precondition. Distributing through TestFlight or the App Store would need a Production
  environment, a deployed schema and a fresh owner decision.

## Scope amendment (2026-09-25)

Rhys closed the remaining scope. Whirr stays an Audiobookshelf client whose distinguishing trait
is that it is self-contained around the listener's own server; good standalone podcast apps
already exist, and Whirr is a personal app.

- **Delivered and kept:** opt-in private CloudKit sync of native podcast state as described above,
  manual `.whirrpodcasts.json` backup and fill-in restore, and the separate native settings, queue
  and saved tables.
- **Dropped:** native podcasts usable without an Audiobookshelf account. The sentence in the
  Decision section saying they "become usable without an Audiobookshelf account" no longer
  describes intended behaviour: the app still requires an ABS account to reach any screen, and the
  background refresh still requires an account row. ADR 0004's account requirement therefore
  stands for the app shell; its other supersessions above (RSS state may reach private iCloud,
  native rows survive logout) remain in force because the delivered sync and native tables rely
  on them.
- **Automatic backup:** the full rotating design is not planned. A foreground-only minimal
  version, which needs no new capability, was approved on 2026-09-25 as IC5-min in the
  private plan.

## TestFlight amendment (2026-11-08)

Rhys decided on 2026-11-08 to distribute Whirr through external TestFlight again, and that CloudKit
podcast sync goes live in that build. This replaces the personal-distribution amendment's
"every build is development-signed" premise; its decision to enable sync in Release stands.

- `Whirr.entitlements` (Release) now selects `aps-environment` `production` and
  `icloud-container-environment` `Production`. `WhirrDebug.entitlements` is unchanged and stays in
  Development. Debug and Release therefore share the container but not the database.
  `ReleaseAuditTests` pins each file to its own environment and refuses the other's values.
- `PodcastCloudSyncComposition.destination` names `production` in Release and `development` in
  Debug. The environment is part of the sync namespace, so an install that moves from a
  Development build to a Production one runs the bootstrap barrier again against the empty
  Production zone instead of reusing engine state from the other database. Nothing is migrated
  between the two databases; each device uploads its local state on that first bootstrap.
- The Development schema must be deployed to Production in the CloudKit Console before the first
  Production build syncs. That deployment is permanent: record types and fields cannot later be
  removed from Production.
- The IC0 physical rows (relaunch state, account switch, Data Protection, provider revocation)
  remain field evidence, now on the Production environment.
