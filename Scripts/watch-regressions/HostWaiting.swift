import Foundation

// The host programs' bounded waits. They are standalone executables without Swift Testing, so
// they cannot link `TestSupport`'s `awaitCondition`/`awaitQuiescence`; these keep the same
// contract in miniature. The budget counts serviced 1 ms polls, not wall-clock time, and a wait
// that runs out stops the program with its label and the state it last saw, instead of falling
// through to an assertion about something else. `run.py`'s 120 s program timeout is the outer
// bound. `WaiterPatternTests` scans this folder, so a hand-written yield loop fails the gate.

/// Waits until `condition` holds, or stops the program saying what it waited for.
func hostAwait(
  _ label: String,
  polls: Int = 5_000,
  isolation: isolated (any Actor)? = #isolation,
  observing state: () async -> String = { "" },
  until condition: () async -> Bool
) async {
  for _ in 0..<polls {
    if await condition() { return }
    await hostPoll(label)
  }
  if await condition() { return }
  let observed = await state()
  preconditionFailure(
    "timed out waiting for \(label) after \(polls) serviced polls"
      + (observed.isEmpty ? "" : "; observed state: \(observed)"))
}

/// Waits until `signal` has reported the same value for `stableFor` consecutive serviced polls.
/// A bound for asserting that something did not happen, not a proof: wait on an acknowledgement
/// instead where the work gives one.
func hostAwaitQuiescence(
  _ label: String,
  stableFor: Int = 20,
  polls: Int = 5_000,
  isolation: isolated (any Actor)? = #isolation,
  of signal: () async -> String
) async {
  var last = await signal()
  var stable = 0
  for _ in 0..<polls {
    await hostPoll(label)
    let current = await signal()
    stable = current == last ? stable + 1 : 0
    last = current
    if stable >= stableFor { return }
  }
  preconditionFailure("never settled while waiting for \(label) after \(polls) serviced polls; last: \(last)")
}

private func hostPoll(_ label: String) async {
  do { try await Task.sleep(for: .milliseconds(1)) } catch { preconditionFailure("cancelled waiting for \(label)") }
}
