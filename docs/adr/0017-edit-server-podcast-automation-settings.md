# ADR 0017: An administrator may edit a server show's automation settings

- Status: Accepted (2026-11-11, Rhys) as the carve-out the
  podcast server automation plan needs (PSA-OD1).
  The plan's implementation stages are approved separately; this record permits the write, it
  does not start the work
- Date: 2026-11-11
- Amends: [ADR 0002](0002-device-podcast-auto-download.md),
  [ADR 0004](0004-native-rss-podcast-subscriptions.md),
  [ADR 0006](0006-save-native-podcast-episodes-to-audiobookshelf.md) and
  [API-CONVENTIONS](../API-CONVENTIONS.md) rule 26, each of which said these settings were
  read-only in Whirr

## Context

Audiobookshelf decides, per show, whether it downloads new episodes by itself, how often it
checks, how many new episodes one check may take, and how many it keeps. Whirr has shown those
four values read-only, with a footer sending the administrator to the web app.

Two things changed. Saving a followed RSS show's episode to the server (ADR 0006) creates the
show there with automatic downloads off, so the administrator has to leave Whirr to finish what
Whirr started. And the owner's position (2026-11-11) is that RSS podcasts and Audiobookshelf
integration are the features Whirr competes on, so that last step belongs in the app.

[ADR 0015](0015-server-lists-are-read-only-in-whirr.md) removed server-list editing three days
earlier. It is not a general rule against server edits: its reasons were four overlapping "keep
this" destinations and 5,000 lines for a days-old feature. This write is four fields on a
screen that already exists.

## Decision

Whirr may change one server show's automation settings, through one route, with a closed body.

1. **Route.** `PATCH /api/items/:id/media`. On the server this is the general item-media edit:
   it also accepts metadata, tags, a cover URL and `lastEpisodeCheck`. Whirr's request type
   encodes only the four fields below, and a key-set test pins that.
2. **Fields.**
   - `autoDownloadEpisodes`: a JSON boolean.
   - `autoDownloadSchedule`: one of Whirr's preset cron expressions. Never free text, never
     empty and never null.
   - `maxNewEpisodesToDownload`: a positive integer within a bound `ABSApi` validates. Never
     `0`, which the server reads as "no limit".
   - `maxEpisodesToKeep`: a non-negative bounded integer; `0` means "keep all".
3. **Who.** An account the shared capability admits as live, active `admin` or `root` with
   `permissions.update`: the rule ADR 0006 uses for Save. The server would admit any account
   holding `update`; Whirr does not offer it to them. Widening that is an amendment to this ADR.
4. **How.** An explicit action in Show Settings. Online-only: no outbox entry, no optimistic
   value, no automatic retry beyond the transport's single resend after a `401`. The result is
   confirmed against the server before it is shown as saved. A `403` is authoritative and drops
   the cached capability.
5. **Where.** `ABSApi` owns the request and its validation. A `SyncEngine` service sends it and
   checks that the account has not changed between the send and the stored result. It is not
   the NP12 coordinator and shares no state with the save attempt table.
6. **The one write the user does not set directly.** When **Save Show to Audiobookshelf** has
   just created a show, Whirr turns `autoDownloadEpisodes` on for it, after saying so in the
   destination prompt. It sends nothing when the show already existed.
7. **A followed RSS show may display these settings** once a server copy of its feed exists.
   The values come only from the server item, never from the device's own feed settings.

## Still prohibited

Feed checks on demand, download-queue reads or control, library scans, show metadata edit,
show delete, removal of episodes Whirr did not save, ordinary-user writes, anything for a feed
with a device-held credential, and any timer, poller or socket added for this. Rule 26 and
ADR 0006 keep governing all of those.

## Why these limits

Each comes from the server's behaviour, recorded on disposable v2.35.1, v2.36.0 and v2.37.2
instances (PSA.0 ledger).

- **The closed body.** The route accepts far more than these fields, and the server validates
  almost nothing: a negative or fractional limit and an empty schedule are all stored. Only a
  cron expression it cannot parse is refused. Whirr's own validation is the only guard.
- **No zero limit.** With `maxNewEpisodesToDownload` at `0` the next check takes every episode
  newer than the newest one the server holds. On a show whose only server episode is old, that
  is most of the feed.
- **Admin only.** The server's gate is `update` alone, so an ordinary account granted `update`
  can already do this on the web. Offering it in Whirr to accounts that cannot create the show
  or save an episode would split the feature across two permission rules.
- **Explicit and online.** The setting changes what a shared server downloads and deletes. A
  queued write replayed hours later could undo a change someone else made on the web.

## Consequences

- Turning automatic downloads on, or raising a limit, makes a shared server fetch and store
  more. Lowering **Keeps** makes it delete: the server removes the oldest episode each time a
  scheduled download lands, including episodes Whirr saved by hand.
- An episode Whirr saved and the server later removes still reads "Saved on server", because a
  confirmed save attempt is never re-read. That defect predates this ADR and is tracked
  separately (PSA-OD14).
- The documents this amends now name two exceptions to "Audiobookshelf owns podcast
  administration". A third needs its own ADR, not an extension of this one.
- Removing the feature means deleting one endpoint, one service and one editor; nothing else
  depends on them.
