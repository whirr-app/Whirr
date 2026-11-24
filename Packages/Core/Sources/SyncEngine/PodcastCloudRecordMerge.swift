import Foundation
import Persistence

extension PodcastCloudStampFields {
  public init(_ stamp: PodcastCloudMutationStamp) {
    self.init(
      physicalMilliseconds: stamp.physicalMilliseconds, logicalCounter: stamp.logicalCounter,
      installationUUID: stamp.installationUUID.uuidString.lowercased(),
      mutationUUID: stamp.mutationUUID.uuidString.lowercased())
  }
}

extension PodcastCloudMutationStamp {
  /// `nil` for stored text that is not a valid stamp, which a caller treats as "nothing accepted".
  public init?(_ fields: PodcastCloudStampFields) {
    guard let installation = UUID(uuidString: fields.installationUUID),
      let mutation = UUID(uuidString: fields.mutationUUID),
      let stamp = try? PodcastCloudMutationStamp(
        physicalMilliseconds: fields.physicalMilliseconds, logicalCounter: fields.logicalCounter,
        installationUUID: installation, mutationUUID: mutation)
    else { return nil }
    self = stamp
  }
}

/// Record-level merge for `serverRecordChanged` and for a fetched record that meets a pending
/// local send, built from the algebraic entity merges.
///
/// Answers whether the server's record already carries the winning value or this device must
/// publish. "Keep the server" also covers an exact echo, so a duplicate remote apply cannot create
/// a new mutation or echo loop.
public enum PodcastCloudRecordMerge {
  public enum Outcome: Sendable, Equatable {
    /// The server record wins or already equals the merge. Nothing to send.
    case keepServer
    /// These fields win and must be published, conditional on the server record's change tag.
    case publish(PodcastCloudRecordFields)
    /// The server's episode state has a newer explicit epoch but met this device's own unsent
    /// listening. `local` is kept and treated as a new explicit action: the caller mints a fresh
    /// HLC stamp (greater than the admitted remote epoch, since admission advances the clock),
    /// sets it as both `explicitEpoch` and `writeStamp`, and publishes. Never applies when `local`
    /// is itself an equal-standing explicit action; that is compared by stamp like any register.
    case adoptLocalAsExplicit(PodcastCloudRecordFields)
  }

  public enum Failure: Error, Sendable, Equatable {
    case recordMismatch
    /// Two different values under one stamp. A stamp names one mutation, so this is corruption
    /// or a defective writer, and it is held rather than resolved by guesswork.
    case stampCollision
  }

  /// A placeholder identity for decoding a subscription record purely to merge it. The record
  /// never stores the subscription UUID (the name is its keyed form), and both sides of one merge
  /// are the same subscription by construction, so any fixed value serves.
  private static let mergeSubscriptionUUID = UUID(uuidString: "00000000-0000-8000-8000-000000000000")!

  /// The newest stamp a record carries, which its accepted-stamp bookkeeping and clock admission
  /// are about. `nil` for the keyring, which is write-once and unstamped.
  public static func governingStamp(of fields: PodcastCloudRecordFields) throws
    -> PodcastCloudMutationStamp?
  {
    guard let type = PodcastCloudRecordLayout.recordType(named: fields.recordType) else {
      throw PodcastCloudRecordMappingError.undeclaredField(fields.recordType)
    }
    let reader = PodcastCloudRecordReader(type: type, fields: fields)
    try reader.validateSchema()
    switch type.name {
    case PodcastCloudRecordLayout.keyring.name:
      return nil
    case PodcastCloudRecordLayout.subscription.name:
      let follow = try reader.stamp(prefix: "follow")
      guard let customOrder = try? reader.stamp(prefix: "customOrder") else { return follow }
      return max(follow, customOrder)
    case PodcastCloudRecordLayout.savedEpisode.name:
      return try reader.stamp(prefix: "saved")
    default:
      return try reader.stamp(prefix: "write")
    }
  }

  public static func merge(
    local: PodcastCloudRecordFields, server: PodcastCloudRecordFields,
    hasUnsentListening: Bool = false
  ) throws -> Outcome {
    guard local.recordType == server.recordType, local.recordName == server.recordName else {
      throw Failure.recordMismatch
    }
    if local == server { return .keepServer }
    switch local.recordType {
    case PodcastCloudRecordLayout.keyring.name:
      // Write-once: whichever key reached the server first is the account's key.
      return .keepServer
    case PodcastCloudRecordLayout.episodeState.name:
      let localValue = try PodcastCloudRecordCodec.decodeEpisodeState(local)
      let serverValue = try PodcastCloudRecordCodec.decodeEpisodeState(server)
      let winner = try collisionChecked {
        try PodcastCloudEpisodeState.merge(localValue.state, serverValue.state)
      }
      guard winner == serverValue.state else { return .publish(local) }
      // The pure value merge ignores whether this device's own value is unsent listening for
      // the same episode, which the caller may know. Only a strictly newer explicit epoch
      // qualifies; an equal epoch is an ordinary tick race under the same explicit action,
      // decided by write stamp.
      if hasUnsentListening, serverValue.state.explicitEpoch > localValue.state.explicitEpoch {
        return .adoptLocalAsExplicit(local)
      }
      return .keepServer
    case PodcastCloudRecordLayout.savedEpisode.name:
      let localValue = try PodcastCloudRecordCodec.decodeSavedRegister(local)
      let serverValue = try PodcastCloudRecordCodec.decodeSavedRegister(server)
      let winner = try collisionChecked { try PodcastCloudSavedRegister.merge(localValue, serverValue) }
      return winner == serverValue ? .keepServer : .publish(local)
    case PodcastCloudRecordLayout.subscription.name:
      return try mergeSubscription(local: local, server: server)
    case PodcastCloudRecordLayout.episodeIdentity.name:
      return try mergeIdentity(local: local, server: server)
    default:
      // Global settings, feed settings and the bookmark are whole LWW registers on one stamp.
      let localStamp = try governingStamp(of: local)
      let serverStamp = try governingStamp(of: server)
      guard let localStamp, let serverStamp else { return .keepServer }
      if localStamp == serverStamp { throw Failure.stampCollision }
      return localStamp > serverStamp ? .publish(local) : .keepServer
    }
  }

  /// The follow lifecycle and the custom-order position are independent registers carried by one
  /// record, so each merges on its own stamp and the record is reassembled. Descriptive
  /// metadata travels with the winning lifecycle.
  private static func mergeSubscription(
    local: PodcastCloudRecordFields, server: PodcastCloudRecordFields
  ) throws -> Outcome {
    let localValue = try PodcastCloudRecordCodec.decodeSubscription(
      local, subscriptionUUID: mergeSubscriptionUUID)
    let serverValue = try PodcastCloudRecordCodec.decodeSubscription(
      server, subscriptionUUID: mergeSubscriptionUUID)
    let lifecycle = try collisionChecked {
      try PodcastCloudFollowRegister.merge(localValue.lifecycle, serverValue.lifecycle)
    }
    let customOrder: StampedCustomOrder?
    switch (localValue.customOrder, serverValue.customOrder) {
    case (nil, let order), (let order, nil): customOrder = order
    case (let lhs?, let rhs?):
      if lhs.stamp == rhs.stamp, lhs != rhs { throw Failure.stampCollision }
      customOrder = lhs.stamp > rhs.stamp ? lhs : rhs
    }
    let metadata = lifecycle == serverValue.lifecycle ? serverValue : localValue
    let merged = SubscriptionSnapshot(
      subscriptionUUID: mergeSubscriptionUUID,
      canonicalizationVersion: metadata.canonicalizationVersion,
      normalizedURL: metadata.normalizedURL, title: metadata.title, author: metadata.author,
      subscribedAt: metadata.subscribedAt, lifecycle: lifecycle, customOrder: customOrder)
    if merged == serverValue { return .keepServer }
    return .publish(try PodcastCloudRecordCodec.encode(subscription: merged, recordName: server.recordName))
  }

  /// Identity records union-merge alias components: an alias either device admitted is
  /// evidence neither may drop, and the representative is the lexicographically smallest digest.
  /// Union is commutative and idempotent, so two devices publishing their unions converge.
  private static func mergeIdentity(
    local: PodcastCloudRecordFields, server: PodcastCloudRecordFields
  ) throws -> Outcome {
    let type = PodcastCloudRecordLayout.episodeIdentity
    let localReader = PodcastCloudRecordReader(type: type, fields: local)
    let serverReader = PodcastCloudRecordReader(type: type, fields: server)
    try localReader.validateSchema()
    try serverReader.validateSchema()
    let localStamp = try localReader.stamp(prefix: "write")
    let serverStamp = try serverReader.stamp(prefix: "write")
    guard case .string(let localRepresentative) = try localReader.required("representativeDigest"),
      case .string(let serverRepresentative) = try serverReader.required("representativeDigest")
    else { throw PodcastCloudRecordMappingError.missingRequiredField("representativeDigest") }

    let aliases = Set(try localReader.stringList("aliases") ?? [])
      .union(try serverReader.stringList("aliases") ?? []).sorted()
    let newer = localStamp > serverStamp ? localReader : serverReader
    var builder = PodcastCloudRecordBuilder(type: type, recordName: server.recordName)
    try builder.set("representativeDigest", .string(min(localRepresentative, serverRepresentative)))
    try builder.set("aliases", aliases.isEmpty ? nil : .stringList(aliases))
    try builder.set("guid", try newer.string("guid").map { .string($0) })
    try builder.set("enclosureURL", try newer.string("enclosureURL").map { .string($0) })
    try builder.set(stamp: max(localStamp, serverStamp), prefix: "write")
    let merged = try builder.build()
    return merged == server ? .keepServer : .publish(merged)
  }

  /// True when `local` was produced as a tick (its explicit epoch is strictly older than its
  /// write stamp) and its position differs from `server`'s. Pure and clock-free. An explicit
  /// action (`explicitEpoch == writeStamp`) never qualifies, so an explicit-against-explicit
  /// conflict is still decided by stamp.
  public static func isUnsentTick(
    local: PodcastCloudEpisodeState, server: PodcastCloudEpisodeState
  ) -> Bool {
    local.explicitEpoch < local.writeStamp && local.position != server.position
  }

  private static func collisionChecked<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch PodcastCloudEpisodeState.ValidationError.stampCollision {
      throw Failure.stampCollision
    } catch PodcastCloudSavedRegister.ValidationError.stampCollision {
      throw Failure.stampCollision
    } catch PodcastCloudFollowRegister.ValidationError.stampCollision {
      throw Failure.stampCollision
    }
  }

  // MARK: - Size

  /// Fixed allowance for the record's type, name and system fields on the wire.
  static let recordOverheadBytes = 512

  /// An estimate of a record's encoded field payload, for the byte-aware batch supplier.
  /// Generous on purpose: an underestimate only costs a `limitExceeded` split and an overestimate
  /// only a smaller batch, and neither replaces server validation.
  public static func estimatedBytes(of fields: PodcastCloudRecordFields) -> Int {
    var total = recordOverheadBytes + fields.recordName.utf8.count + fields.recordType.utf8.count
    for (name, value) in fields.plaintext {
      total += name.utf8.count + estimatedBytes(of: value)
    }
    for (name, value) in fields.encrypted {
      total += name.utf8.count + estimatedBytes(of: value)
    }
    return total
  }

  private static func estimatedBytes(of value: PodcastCloudRecordValue) -> Int {
    switch value {
    case .string(let string): string.utf8.count
    case .integer, .double, .date: 8
    case .boolean: 1
    case .data(let data): data.count
    // Encrypted values carry per-element framing; four bytes each is a conservative allowance.
    case .stringList(let list): list.reduce(0) { $0 + $1.utf8.count + 4 }
    }
  }
}
