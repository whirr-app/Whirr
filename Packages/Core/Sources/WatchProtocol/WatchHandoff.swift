import Foundation

/// One device asks the other to pause and say where it was. It carries no lease,
/// generation or owner: the devices are peers, and the newest listen settles progress later.
/// `selection` is the title the asking device is about to play; `nil` is a title the other
/// device cannot name (a native feed episode), which still asks it to pause.
public struct WatchHandoffRequest: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public static let transportKey = WatchTransportKey.handoff
  public let version: Int
  public let handoffID: UUID
  public let accountStamp: WatchAccountStamp
  public let selection: WatchABSSelection?
  public let issuedAt: Date

  public init(
    handoffID: UUID = UUID(), accountStamp: WatchAccountStamp, selection: WatchABSSelection?,
    issuedAt: Date = Date()
  ) throws {
    self.version = WatchProtocolVersion.current
    self.handoffID = handoffID
    self.accountStamp = accountStamp
    self.selection = selection
    self.issuedAt = issuedAt
    try validate()
  }

  private enum CodingKeys: String, CodingKey { case version, handoffID, accountStamp, selection, issuedAt }
  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try selection?.validate()
    guard issuedAt.timeIntervalSinceReferenceDate.isFinite else { throw WatchHandoffError.invalidValue }
  }
}

public enum WatchHandoffStatus: String, Codable, Sendable, Equatable {
  /// A title was loaded; it is now paused and stays loaded. The reply names it and its position.
  case paused
  /// Nothing was loaded.
  case idle
  /// The request was refused and nothing was paused.
  case rejected
}

public enum WatchHandoffRejection: String, Codable, Sendable, Equatable {
  case wrongAccount
  case expired
  case invalid
}

/// The answer to a `WatchHandoffRequest`. The asking device uses the position only when the
/// selection is the title it is starting, and weighs it by `lastListenedAt` rather than
/// trusting it outright: a paused title may have been played further elsewhere since.
public struct WatchHandoffReply: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public let version: Int
  public let handoffID: UUID
  public let status: WatchHandoffStatus
  public let selection: WatchABSSelection?
  public let positionSeconds: Double?
  public let lastListenedAt: Date?
  public let rejection: WatchHandoffRejection?

  public init(
    handoffID: UUID, status: WatchHandoffStatus, selection: WatchABSSelection? = nil,
    positionSeconds: Double? = nil, lastListenedAt: Date? = nil, rejection: WatchHandoffRejection? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.handoffID = handoffID
    self.status = status
    self.selection = selection
    self.positionSeconds = positionSeconds
    self.lastListenedAt = lastListenedAt
    self.rejection = rejection
    try validate()
  }

  /// Whatever was loaded is paused; `selection` is `nil` when it was a title the other device
  /// cannot name, whose position is then of no use to it.
  public static func paused(
    _ request: WatchHandoffRequest, selection: WatchABSSelection?, position: Double, lastListenedAt: Date?
  ) throws -> WatchHandoffReply {
    try WatchHandoffReply(
      handoffID: request.handoffID, status: .paused, selection: selection,
      positionSeconds: selection == nil ? nil : position, lastListenedAt: selection == nil ? nil : lastListenedAt)
  }

  public static func idle(_ request: WatchHandoffRequest) -> WatchHandoffReply {
    try! WatchHandoffReply(handoffID: request.handoffID, status: .idle)
  }

  public static func rejected(handoffID: UUID, _ rejection: WatchHandoffRejection) -> WatchHandoffReply {
    try! WatchHandoffReply(handoffID: handoffID, status: .rejected, rejection: rejection)
  }

  /// The position to start `selection` from, when this reply is about that title.
  public func position(for selection: WatchABSSelection?) -> Double? {
    guard status == .paused, let selection, self.selection == selection else { return nil }
    return positionSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case version, handoffID, status, selection, positionSeconds, lastListenedAt, rejection
  }
  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try selection?.validate()
    if let positionSeconds {
      guard positionSeconds.isFinite, positionSeconds >= 0, positionSeconds <= WatchHandoffLimits.maxPositionSeconds
      else { throw WatchHandoffError.invalidValue }
    }
    if let lastListenedAt {
      guard lastListenedAt.timeIntervalSinceReferenceDate.isFinite else { throw WatchHandoffError.invalidValue }
    }
    let valid: Bool =
      switch status {
      case .paused: rejection == nil && (selection == nil) == (positionSeconds == nil)
      case .idle: rejection == nil && selection == nil && positionSeconds == nil && lastListenedAt == nil
      case .rejected: rejection != nil && selection == nil && positionSeconds == nil && lastListenedAt == nil
      }
    guard valid else { throw WatchHandoffError.invalidValue }
  }
}

/// What the Watch is playing, published in its application context on every transition into or
/// out of playing. The Watch cannot retract it once out of range, so a reader treats it as
/// expired `expiry` after `observedAt`.
public struct WatchPlayingReport: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public static let transportKey = WatchTransportKey.playingReport
  /// How long a report stays useful after it was observed.
  public static let expiry: TimeInterval = 3 * 60
  /// How often a Watch that keeps playing repeats its report, so it does not lapse mid-listen.
  public static let refreshInterval: TimeInterval = 2 * 60

  /// Whether a Watch that is still playing should repeat the report it last published.
  public static func refreshDue(lastPublished: Date?, now: Date) -> Bool {
    guard let lastPublished else { return true }
    let age = now.timeIntervalSince(lastPublished)
    return age < 0 || age >= refreshInterval
  }
  public let version: Int
  public let accountStamp: WatchAccountStamp
  /// The Audiobookshelf title being played, if it is one. The ABS-only guarantee on this field is
  /// kept: an RSS episode is named only through `nativeSelection`, and the wire never claims that
  /// the Watch can play it. Playability comes from a received copy the Watch already holds
  /// (ADR 0019 decision 3).
  public let selection: WatchABSSelection?
  /// The native-RSS episode being played, if it is one. Absent from an older Watch and from any
  /// ABS report, and then `nil`.
  public let nativeSelection: WatchNativeSelection?
  public let playing: Bool
  public let observedAt: Date

  public init(
    accountStamp: WatchAccountStamp, selection: WatchABSSelection?, playing: Bool, observedAt: Date,
    nativeSelection: WatchNativeSelection? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.accountStamp = accountStamp
    self.selection = selection
    self.nativeSelection = nativeSelection
    self.playing = playing
    self.observedAt = observedAt
    try validate()
  }

  /// Whether this report says the Watch is playing, for `accountStamp`, at `now`.
  public func isPlaying(for accountStamp: WatchAccountStamp?, at now: Date) -> Bool {
    guard playing, accountStamp == self.accountStamp else { return false }
    let age = now.timeIntervalSince(observedAt)
    return age >= -WatchProtocolVersion.commandFutureSkewTolerance && age < Self.expiry
  }

  private enum CodingKeys: String, CodingKey {
    case version, accountStamp, selection, nativeSelection, playing, observedAt
  }
  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try selection?.validate()
    try nativeSelection?.validate()
    guard observedAt.timeIntervalSinceReferenceDate.isFinite,
      selection == nil || nativeSelection == nil,
      !playing || selection != nil || nativeSelection != nil
    else { throw WatchHandoffError.invalidValue }
  }
}

/// The answering side of a handoff, without the transport: the account check, the admission
/// window (so a delayed request cannot pause a later listen) with its future-skew bound, and a
/// bounded replay cache. Pausing is idempotent, but a repeat must not pause a title the user
/// resumed after the first delivery, so a repeat only reports the current state.
public struct WatchHandoffResponder: Sendable {
  public enum Admission: Sendable, Equatable {
    /// First delivery: pause whatever is loaded, keep it loaded, and reply with it.
    case pause(WatchHandoffRequest)
    /// A repeat of an admitted request: reply with the current state without pausing.
    case report(WatchHandoffRequest)
    case reject(WatchHandoffReply)
  }

  public static let capacity = 32
  private var admitted: [UUID: Date] = [:]

  public init() {}

  public mutating func admit(
    _ request: WatchHandoffRequest, authenticatedAccountStamp: WatchAccountStamp?, now: Date
  ) -> Admission {
    guard request.accountStamp == authenticatedAccountStamp else {
      return .reject(.rejected(handoffID: request.handoffID, .wrongAccount))
    }
    let age = now.timeIntervalSince(request.issuedAt)
    guard age.isFinite, age >= -WatchProtocolVersion.commandFutureSkewTolerance,
      age < WatchProtocolVersion.commandAdmissionWindow
    else { return .reject(.rejected(handoffID: request.handoffID, .expired)) }
    admitted = admitted.filter { $0.value > now }
    if admitted[request.handoffID] != nil { return .report(request) }
    if admitted.count >= Self.capacity, let oldest = admitted.min(by: { $0.value < $1.value })?.key {
      admitted.removeValue(forKey: oldest)
    }
    admitted[request.handoffID] = request.issuedAt.addingTimeInterval(WatchProtocolVersion.commandAdmissionWindow)
    return .pause(request)
  }

  /// An account change forgets every admitted request.
  public mutating func reset() { admitted.removeAll() }
}
