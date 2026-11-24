import Foundation

/// Persisted HLC bookkeeping. The monotonic anchor is process-local and is absent
/// from this Codable value; after relaunch a persisted server anchor cannot be used as elapsed time.
public struct PodcastCloudClockState: Codable, Sendable, Equatable {
  public fileprivate(set) var physicalMilliseconds: Int64
  public fileprivate(set) var logicalCounter: Int64
  public let installationUUID: UUID
  public fileprivate(set) var anchorServerMilliseconds: Int64?
  public fileprivate(set) var lastAdmittedPhysicalMilliseconds: Int64
  public fileprivate(set) var lastAdmittedLogicalCounter: Int64
  public fileprivate(set) var repairRequired: Bool

  public init(
    installationUUID: UUID, physicalMilliseconds: Int64 = 0,
    logicalCounter: Int64 = 0, anchorServerMilliseconds: Int64? = nil,
    lastAdmittedPhysicalMilliseconds: Int64 = 0,
    lastAdmittedLogicalCounter: Int64 = 0, repairRequired: Bool = false
  ) throws {
    guard physicalMilliseconds >= 0, logicalCounter >= 0,
      (anchorServerMilliseconds ?? 0) >= 0,
      lastAdmittedPhysicalMilliseconds >= 0, lastAdmittedLogicalCounter >= 0,
      physicalMilliseconds > lastAdmittedPhysicalMilliseconds
        || (physicalMilliseconds == lastAdmittedPhysicalMilliseconds
          && logicalCounter >= lastAdmittedLogicalCounter)
    else {
      throw PodcastCloudClock.Error.invalidState
    }
    self.installationUUID = installationUUID
    self.physicalMilliseconds = physicalMilliseconds
    self.logicalCounter = logicalCounter
    self.anchorServerMilliseconds = anchorServerMilliseconds
    self.lastAdmittedPhysicalMilliseconds = lastAdmittedPhysicalMilliseconds
    self.lastAdmittedLogicalCounter = lastAdmittedLogicalCounter
    self.repairRequired = repairRequired
  }

  private enum CodingKeys: String, CodingKey {
    case physicalMilliseconds, logicalCounter, installationUUID, anchorServerMilliseconds,
      lastAdmittedPhysicalMilliseconds, lastAdmittedLogicalCounter, repairRequired
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      installationUUID: c.decode(UUID.self, forKey: .installationUUID),
      physicalMilliseconds: c.decode(Int64.self, forKey: .physicalMilliseconds),
      logicalCounter: c.decode(Int64.self, forKey: .logicalCounter),
      anchorServerMilliseconds: c.decodeIfPresent(Int64.self, forKey: .anchorServerMilliseconds),
      lastAdmittedPhysicalMilliseconds: c.decode(Int64.self, forKey: .lastAdmittedPhysicalMilliseconds),
      lastAdmittedLogicalCounter: c.decode(Int64.self, forKey: .lastAdmittedLogicalCounter),
      repairRequired: c.decodeIfPresent(Bool.self, forKey: .repairRequired) ?? false)
  }
}

public struct PodcastCloudClock: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable { case invalidState, counterOverflow, quarantined }
  public static let quarantineWindowMilliseconds: Int64 = 24 * 60 * 60 * 1000
  public private(set) var state: PodcastCloudClockState
  /// The monotonic reading at which this process observed `state.anchorServerMilliseconds`.
  public private(set) var monotonicAnchor: Int64?

  /// `monotonicAnchor` is only ever a reading this process took for this state's server anchor;
  /// `PodcastCloudMonotonicSource` is what carries it between per-transaction clocks.
  public init(state: PodcastCloudClockState, monotonicAnchor: Int64? = nil) {
    self.state = state
    self.monotonicAnchor = state.anchorServerMilliseconds == nil ? nil : monotonicAnchor
  }

  /// Generates a local stamp. Once anchored, wall-clock jumps are ignored until a fresh server
  /// anchor is observed; monotonic elapsed time is the only permitted advancement.
  public mutating func generate(
    wallClockMilliseconds: Int64, monotonicMilliseconds: Int64? = nil,
    mutationUUID: UUID = UUID()
  ) throws -> PodcastCloudMutationStamp {
    guard wallClockMilliseconds >= 0 else { throw Error.invalidState }
    guard state.repairRequired == false else { throw Error.quarantined }
    let candidate: Int64
    if let anchor = state.anchorServerMilliseconds {
      if let monotonicMilliseconds {
        guard monotonicMilliseconds >= 0 else { throw Error.invalidState }
        guard let base = monotonicAnchor else {
          // A persisted server anchor is not a process monotonic anchor.
          return try generate(wallClockMilliseconds: wallClockMilliseconds, mutationUUID: mutationUUID)
        }
        guard monotonicMilliseconds >= base else { throw Error.invalidState }
        let elapsed = monotonicMilliseconds - base
        guard elapsed >= 0, anchor <= Int64.max - elapsed else { throw Error.invalidState }
        candidate = anchor + elapsed
      } else {
        candidate = state.physicalMilliseconds
      }
    } else {
      candidate = wallClockMilliseconds
    }
    let physical = max(candidate, state.physicalMilliseconds)
    let counter: Int64
    if physical == state.physicalMilliseconds {
      guard state.logicalCounter < Int64.max else { throw Error.counterOverflow }
      counter = state.logicalCounter + 1
    } else {
      counter = 0
    }
    state.physicalMilliseconds = physical
    state.logicalCounter = counter
    return try PodcastCloudMutationStamp(
      physicalMilliseconds: physical, logicalCounter: counter,
      installationUUID: state.installationUUID, mutationUUID: mutationUUID)
  }

  /// Admits an immutable remote stamp against its record server modification date. A rejected
  /// value never advances local HLC state.
  public mutating func observe(
    _ stamp: PodcastCloudMutationStamp,
    serverModificationMilliseconds: Int64,
    monotonicMilliseconds: Int64? = nil
  ) throws {
    guard serverModificationMilliseconds >= 0 else { throw Error.invalidState }
    if let monotonicMilliseconds, monotonicMilliseconds < 0 { throw Error.invalidState }
    if stamp.physicalMilliseconds > serverModificationMilliseconds,
      stamp.physicalMilliseconds - serverModificationMilliseconds > Self.quarantineWindowMilliseconds
    {
      throw Error.quarantined
    }
    if state.anchorServerMilliseconds == nil,
      state.physicalMilliseconds > serverModificationMilliseconds,
      state.physicalMilliseconds - serverModificationMilliseconds > Self.quarantineWindowMilliseconds
    {
      state.repairRequired = true
      throw Error.quarantined
    }
    if stamp.physicalMilliseconds > state.physicalMilliseconds {
      state.physicalMilliseconds = stamp.physicalMilliseconds
      state.logicalCounter = stamp.logicalCounter
    } else if stamp.physicalMilliseconds == state.physicalMilliseconds {
      state.logicalCounter = max(state.logicalCounter, stamp.logicalCounter)
    }
    if stamp.physicalMilliseconds > state.lastAdmittedPhysicalMilliseconds
      || (stamp.physicalMilliseconds == state.lastAdmittedPhysicalMilliseconds
        && stamp.logicalCounter > state.lastAdmittedLogicalCounter)
    {
      state.lastAdmittedPhysicalMilliseconds = stamp.physicalMilliseconds
      state.lastAdmittedLogicalCounter = stamp.logicalCounter
    }
    if state.anchorServerMilliseconds == nil || serverModificationMilliseconds > state.anchorServerMilliseconds! {
      state.anchorServerMilliseconds = serverModificationMilliseconds
      monotonicAnchor = monotonicMilliseconds
    }
  }

  /// Explicit clock repair clears bootstrap quarantine without rewriting any admitted remote stamp.
  public mutating func repair(wallClockMilliseconds: Int64) throws {
    guard wallClockMilliseconds >= 0 else { throw Error.invalidState }
    state.physicalMilliseconds = max(wallClockMilliseconds, state.lastAdmittedPhysicalMilliseconds)
    state.logicalCounter =
      state.physicalMilliseconds == state.lastAdmittedPhysicalMilliseconds
      ? state.lastAdmittedLogicalCounter : 0
    state.repairRequired = false
    monotonicAnchor = nil
  }
}
