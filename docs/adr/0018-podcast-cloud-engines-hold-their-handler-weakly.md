# ADR 0018: Podcast cloud engines hold their handler weakly

- Status: Accepted (2026-11-16, Rhys)
- Date: 2026-11-16
- Resolves: follow-up F2 of the test database template reuse plan

## Context

`PodcastCloudSyncCoordinator` owns its engine (`attach` stores it in `engine`, and nothing clears
it). Every `PodcastCloudSyncing` conformer holds the coordinator, as its
`PodcastCloudSyncHandling` handler, strongly: the App's `PodcastCloudKitSyncEngineAdapter`, and
`FakePodcastCloudEngine` and `FakePodcastCloudSyncing` in `TestSupport`. The pair is a reference
cycle. `disable()` stops the engine but keeps the reference, so a coordinator, its engine and its
`AppDatabase` live until the process exits.

In tests this is why the PodcastCloud suites never release their in-memory stores (plan §4). In
the app, every consent withdrawal, account change or restart of a session leaks one
coordinator–adapter pair. That leak is small, because the database is shared.

## Decision

1. **Ownership runs one way.** The session that creates the coordinator owns it, and the
   coordinator owns its engine. An engine holds its handler with `weak let`, in the adapter and
   in both fakes.
2. **`PodcastCloudSyncHandling` is class-bound** (`AnyObject, Sendable`), which `weak` requires.
   Its conformers are the coordinator (an actor) and `FakePodcastCloudSyncHandling` (a final
   class).
3. **An engine whose handler is gone serves nothing.** It drops events, answers no batch, and
   reports no outstanding work. The fakes do the same as the adapter, so a test cannot pass
   against a more lenient double than production.

## Consequences

- **Production behaviour is unchanged.** `PodcastCloudSyncRuntime.Session`, the pump task and any
  in-flight call already hold the coordinator for as long as it is used. `stopSession()` clears
  the session but keeps a local reference across `disable()`, which stops the engine. The
  adapter's `engine === syncEngine` fence already discards callbacks from a stopped engine.
  After this change the coordinator and adapter are freed once `disable()` returns.
- **Whoever creates a coordinator must keep it.** An engine no longer keeps its handler alive, so
  code that keeps only the engine would find the handler gone. Every caller today keeps the
  coordinator in a session, a harness or a device fixture. Tests that build a fake around an
  inline `FakePodcastCloudSyncHandling()` get a fake with no handler. Those tests only exercise
  the fake's own command contract, which never reaches the handler.
- **`unowned` was rejected.** CloudKit can deliver a delegate callback after the session has gone,
  and `unowned` would trap where `weak` drops the callback.
- Once released, PodcastCloud test stores can be closed and freed, which option A of the template
  plan (a connection pool) needs.
