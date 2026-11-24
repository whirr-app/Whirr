import Foundation

public enum WatchDeduplicationDecision: Sendable, Equatable {
  case execute
  case inFlight
  case replay(WatchReply)
  case conflict
  case saturated
  case expired
}

public enum WatchDeduplicationError: Error, Sendable, Equatable {
  case unknownCommand
  case conflictingCommand
  case invalidReply
}

/// A bounded actor-isolated cache. In-flight entries are never evicted; if all slots are occupied
/// by in-flight work, admission fails closed instead of risking a second playback. Completed
/// entries are evicted oldest-first (by command age) when full, so a burst never rejects a fresh
/// command; only a replay of an id older than the newest `capacity` commands can be missed.
public actor WatchCommandDeduplicator {
  private struct Entry: Sendable {
    let fingerprint: String
    var reply: WatchReply?
    let expiresAt: Date
  }

  public let capacity: Int
  private var entries: [UUID: Entry] = [:]

  public init(capacity: Int = 256) {
    self.capacity = max(1, capacity)
  }

  public func begin(_ command: WatchCommand, now: Date = Date()) throws -> WatchDeduplicationDecision {
    guard now.timeIntervalSinceReferenceDate.isFinite else { throw WatchProtocolCodingError.invalidValue }
    let fingerprint = try command.fingerprint()
    let age = now.timeIntervalSince(command.issuedAt)
    guard age >= -WatchProtocolVersion.commandFutureSkewTolerance else { throw WatchProtocolCodingError.invalidValue }
    guard age < WatchProtocolVersion.commandAdmissionWindow else { return .expired }
    if let entry = entries[command.id] {
      guard entry.fingerprint == fingerprint else { return .conflict }
      if let reply = entry.reply { return .replay(reply) }
      return .inFlight
    }

    if entries.count >= capacity {
      let candidate = entries.filter({ $0.value.reply != nil })
        .min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key
      guard let candidate else { return .saturated }
      entries.removeValue(forKey: candidate)
    }
    entries[command.id] = Entry(
      fingerprint: fingerprint, reply: nil,
      expiresAt: command.issuedAt.addingTimeInterval(WatchProtocolVersion.commandAdmissionWindow))
    return .execute
  }

  @discardableResult
  public func complete(_ command: WatchCommand, with reply: WatchReply) throws -> Bool {
    guard var entry = entries[command.id] else { throw WatchDeduplicationError.unknownCommand }
    let fingerprint = try command.fingerprint()
    guard entry.fingerprint == fingerprint else { throw WatchDeduplicationError.conflictingCommand }
    guard reply.commandID == command.id else { throw WatchDeduplicationError.invalidReply }
    guard entry.reply == nil else { return false }
    entry.reply = reply
    entries[command.id] = entry
    return true
  }

  public func count() -> Int { entries.count }
  public func contains(_ id: UUID) -> Bool { entries[id] != nil }
  public func reset() { entries.removeAll(keepingCapacity: true) }
}

/// The destination shown when a title is opened. This is a preference for the next user
/// action, not an assertion that playback has started.
public enum WatchPlaybackDestination: String, Codable, Sendable, Equatable {
  case phone
  case watch
}

public enum WatchDestinationPreference {
  /// `hasLocalCopy` says whether the Watch holds a complete copy of `selection`. The wire never
  /// claims Watch playability for a native feed, so for `.nativeFeed` the copy is the only evidence
  /// and `capabilities.watchPlayable` is not consulted (ADR 0019).
  public static func supports(
    _ destination: WatchPlaybackDestination,
    selection: WatchSelection,
    capabilities: WatchSelectionCapabilities,
    hasLocalCopy: Bool = false
  ) -> Bool {
    switch destination {
    case .phone: return capabilities.phonePlayable
    case .watch:
      if case .nativeFeed = selection { return hasLocalCopy }
      return capabilities.watchPlayable
    }
  }
}

/// A callback-safe, finish-once reply. The lock protects both the retained result and waiters;
/// continuations are always resumed outside the lock.
public final class WatchReplyGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var result: Value?
  private var continuations: [CheckedContinuation<Value?, Never>] = []

  public init() {}

  public func wait() async -> Value? {
    await withCheckedContinuation { continuation in
      let ready: (Bool, Value?) = lock.withLock {
        if finished { return (true, result) }
        continuations.append(continuation)
        return (false, nil)
      }
      if ready.0 { continuation.resume(returning: ready.1) }
    }
  }

  public func finish(_ value: Value?) {
    let pending: [CheckedContinuation<Value?, Never>] = lock.withLock {
      guard !finished else { return [] }
      finished = true
      result = value
      defer { continuations.removeAll() }
      return continuations
    }
    for continuation in pending { continuation.resume(returning: value) }
  }
}
