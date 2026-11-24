# ADR 0016: An active smart list plays before Up Next

- Status: Accepted (2026-11-14, Rhys), with the Smart Lists plan
  (SL-OD3, SL-OD5, SL-OD12, SL-OD18)
- Date: 2026-11-14
- Amends: [ARCHITECTURE](../ARCHITECTURE.md) D30's rationale. "Up Next is playback state, not
  podcast navigation" stays true; "Up Next is the only next-source" does not

## Context

When a title ends, `PlaybackModel.driveCompletion` starts the head of Up Next and nothing else.
Smart Lists are saved, rule-based episode lists. A listener who plays a list expects its next
episode to follow, even with episodes waiting in Up Next, and expects Up Next to be there,
untouched, when the list is done.

## Decision

1. **A run.** Playing a list, one of its rows, or an episode card opened from it starts a run: at
   most one, stored on the device (`smartListRun`) so it survives relaunch. The run records the
   list and its anchor, the episode the list last started, with that episode's sort key.
2. **Completion asks the run first.** After the sleep-timer guard and the removal of the finished
   episode's own queue row, completion asks the run for its next unfinished episode: the first
   priority-show episode, else the first after the anchor, wrapping to the top. If there is one,
   it starts with origin `.listAdvance` and completion stops there. If there is none, the run
   ends and the same completion goes on to Up Next.
3. **Up Next is untouched** while a run is active, except that starting a list episode which is
   also queued consumes that row, as any start does.
4. **What ends a run.** Stopping it in the Up Next sheet, deleting its list, the list running
   out, and any start that is neither from the list (`.listAdvance` or a list `.begin`) nor of
   the run's anchor episode. Tapping an Up Next row ends it. Play, pause and resume of the
   current episode keep it. The comparison is with the stored anchor, never the asynchronously
   written bookmark.
5. **A failed list advance** stops with the existing silent recoverable error. The run and its
   anchor are kept, and completion does not fall through to Up Next. Retry re-issues
   `.listAdvance`.
6. **Play Next during a run** still queues at the head of Up Next, which plays after the run.
   The confirmation says so ("Plays after Commute").
7. **No source, no run.** When a run's list has no available source (native subscriptions off
   and signed out), completion ignores the run and plays Up Next; the row is kept.

## Consequences

- Up Next is no longer always what plays next. The Up Next sheet shows the run above the queue,
  headed "Playing from <list>", with Stop, and heads the queue "Up Next · plays after <list>".
- Every start site that is not the list's own ends a run by default. A future site that should
  keep it and forgets to will end it, which is the safe failure.
- Lock-screen next-track stays skip forward.
