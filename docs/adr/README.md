# Architecture decision records

An ADR records a durable decision whose rationale needs more room than a line in the
[architecture decision log](../ARCHITECTURE.md#8-decision-log). The
repository working agreement (a private record) makes an agreed ADR one of the two artefacts that
can satisfy the structural-change gate, so check this index before proposing a new one: the
decision you need may already exist, or may have been superseded.

The delivery plans these records cite by name (`…-plan.md`), and the owner-decision ids from
those plans (`WSA-OD11`), are private working documents and are not published. Each record states
its decision in full without them.

Status is what binds. "Accepted" means the decision governs current work. A superseded record is
kept for its reasoning and must not be followed.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-system-scheduled-podcast-refresh.md) | System-scheduled podcast metadata refresh | Accepted (2026-07-27) |
| [0002](0002-device-podcast-auto-download.md) | Device-side podcast auto-download | Accepted (2026-07-28) |
| [0003](0003-watch-shared-protocol-module.md) | Where phone/Watch shared code lives | Accepted for implementation 2026-09-08 |
| [0004](0004-native-rss-podcast-subscriptions.md) | Native RSS podcast subscriptions | Accepted (2026-08-13) |
| [0005](0005-dark-appearance-vetoes-light-ambient-canvases.md) | Dark appearance vetoes light ambient canvases | **Superseded** 2026-09-06 by the app-owned ambient appearance plan (private) |
| [0006](0006-save-native-podcast-episodes-to-audiobookshelf.md) | Save native podcast episodes to Audiobookshelf | Accepted; OD1–OD10 taken at recommended defaults |
| [0007](0007-page-resolved-metadata-ladder.md) | The metadata ladder is resolved against the page, not fixed | Accepted (2026-08-28) |
| [0008](0008-item-detail-is-a-card-at-regular-width.md) | Item detail is a centred card at regular width | Accepted (2026-09-04) |
| [0009](0009-standalone-podcasts-and-private-cloud-state.md) | Standalone podcasts and private CloudKit state | Accepted; sync enabled for Xcode-installed builds (2026-09-24), physical evidence pending |
| [0010](0010-tab-root-titles-stay-on-the-system-default.md) | Tab root titles stay on the system default | Accepted (2026-09-15) |
| [0011](0011-reset-is-a-server-row-deletion.md) | A reset is a server-row deletion, and row identity is the evidence | Accepted (2026-09-27) |
| [0012](0012-episode-card-half-sheet-is-opaque.md) | The episode card's half sheet is opaque | **Superseded** 2026-10-02 by 0013 |
| [0013](0013-episode-card-half-sheet-glass-with-hierarchical-ink.md) | The episode card's half sheet keeps the system glass, with hierarchical ink | Accepted (2026-10-02) |
| [0014](0014-widget-shared-values-live-in-a-package-leaf.md) | App/widget-extension shared values live in a package leaf, `WidgetProtocol` | Accepted (2026-11-06) |
| [0015](0015-server-lists-are-read-only-in-whirr.md) | Audiobookshelf collections and playlists are read-only in Whirr | Accepted (2026-11-08) |
| [0016](0016-active-smart-list-plays-before-up-next.md) | An active smart list plays before Up Next | Accepted (2026-11-14) |
| [0017](0017-edit-server-podcast-automation-settings.md) | An administrator may edit a server show's automation settings | Accepted (2026-11-11); implementation stages await approval |
| [0018](0018-podcast-cloud-engines-hold-their-handler-weakly.md) | Podcast cloud engines hold their handler weakly | Accepted (2026-11-16) |
| [0019](0019-watch-offline-rss-episodes.md) | Watch copies of native RSS episodes, sent by the iPhone | Accepted (2026-11-20); Decisions 1 and 6 superseded by 0020 |
| [0020](0020-watch-fetches-rss-episodes-and-reports-status.md) | The Watch downloads native RSS episodes itself, and reports its own status | Accepted (2026-11-21) |
| [0021](0021-iphone-sends-audiobookshelf-items-to-the-watch.md) | The iPhone sends Audiobookshelf books and episodes to the Watch, and lists all it holds | Accepted (2026-11-21) |

Numbering is sequential and never reused. A superseded ADR keeps its number and gains a pointer to
whatever replaced it, rather than being deleted.
