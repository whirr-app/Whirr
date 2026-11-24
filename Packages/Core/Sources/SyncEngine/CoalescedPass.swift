import Foundation

/// How a caller that arrives while a pass is already in flight is treated.
enum PassJoinPolicy: Sendable {
  /// The joiner waits for the in-flight pass and never starts another.
  case shareInFlight
  /// The joiner's request earns exactly one follow-up pass, which runs before any joiner returns.
  case trailingPass
}

struct CoalescedFlight<Value: Sendable>: Sendable {
  let id: UUID
  let task: Task<Value, Never>
}

/// What one `runCoalescedPass` call did: the pass's value, and whether this call is the one that
/// started it. A caller that owns a side effect only the pass itself should record (such as a
/// "last result" property) gates it on `startedFlight`, so a joiner cannot write it late.
struct CoalescedPassOutcome<Value: Sendable>: Sendable {
  let value: Value
  let startedFlight: Bool
}

/// The flight a coordinator is running, if any. `joinedCount` is test evidence that a concurrent
/// trigger reached the existing flight rather than starting a second pass.
struct CoalescedPassSlot<Value: Sendable>: Sendable {
  var flight: CoalescedFlight<Value>?
  var followUpRequested = false
  var joinedCount = 0
}

/// A coordinator that runs at most one coalesced pass at a time.
///
/// The slot is internal only so the shared helper can reach it; the coordinator is its only writer.
/// Adding a new coordinator means naming `PassValue`, one slot, and one `runCoalescedPass` call.
protocol CoalescedPassHost: Actor {
  associatedtype PassValue: Sendable
  var passSlot: CoalescedPassSlot<PassValue> { get set }
}

extension CoalescedPassHost {
  /// Runs the coordinator's pass, coalescing concurrent callers onto one flight.
  ///
  /// `.shareInFlight` gives a joiner the in-flight pass's result and starts nothing; its flight is
  /// cleared by the caller that started it, so a trigger already queued behind the pass still
  /// joins rather than starting a second one. `.trailingPass` instead records the joiner's request
  /// and runs exactly one more pass before the flight settles, clearing it in the same turn as the
  /// last follow-up check so no caller can join after that check and return uncovered.
  @discardableResult
  func runCoalescedPass(
    policy: PassJoinPolicy,
    perform: @escaping @Sendable () async -> PassValue
  ) async -> CoalescedPassOutcome<PassValue> {
    if let flight = passSlot.flight {
      passSlot.joinedCount += 1
      if policy == .trailingPass {
        passSlot.followUpRequested = true
      }
      return CoalescedPassOutcome(value: await flight.task.value, startedFlight: false)
    }

    let id = UUID()
    let task = Task { await self.drivePass(id: id, policy: policy, perform: perform) }
    passSlot.flight = CoalescedFlight(id: id, task: task)
    let value = await task.value
    if policy == .shareInFlight, passSlot.flight?.id == id {
      passSlot.flight = nil
    }
    return CoalescedPassOutcome(value: value, startedFlight: true)
  }

  private func drivePass(
    id: UUID, policy: PassJoinPolicy, perform: @Sendable () async -> PassValue
  ) async -> PassValue {
    passSlot.followUpRequested = false
    var value = await perform()
    while policy == .trailingPass && passSlot.followUpRequested && Task.isCancelled == false {
      passSlot.followUpRequested = false
      value = await perform()
    }
    if policy == .trailingPass, passSlot.flight?.id == id {
      passSlot.flight = nil
    }
    return value
  }
}
