import ABSApi
import Foundation
import WatchProtocol

/// Durable local-listening sessions for offline playback. The store owns only account-scoped
/// progress values; uploading is performed by SyncEngine through `LocalPlaybackSession`.
public actor WatchOfflineProgressStore {
  public let rootURL: URL
  public let accountStamp: WatchAccountStamp
  public static let maximumUploadBatchSize = 50

  private let persistence: WatchAccountFencedJSONStore<Payload>
  private let now: @Sendable () -> Date
  private var sessionsByID: [UUID: WatchOfflineProgressSession]
  private var inFlightIDs: Set<UUID>
  /// Bumped on every write, in memory only. An acknowledgement deletes a row only when nothing was
  /// written to it after its batch was reserved; a persisted counter would add nothing, because a
  /// restart already requeues every reservation.
  private var revisions: [UUID: Int] = [:]
  private var reservedSnapshots: [UUID: ReservedSnapshot] = [:]

  private struct ReservedSnapshot {
    let revision: Int
    let session: WatchOfflineProgressSession
  }

  struct Payload: Codable, Sendable {
    var sessions: [WatchOfflineProgressSession]
    var inFlightIDs: [UUID]
  }

  public init(
    rootURL: URL,
    accountStamp: WatchAccountStamp,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    Self.excludeFromBackup(rootURL)
    Self.protectPrivateFile(rootURL)
    self.rootURL = rootURL
    self.accountStamp = accountStamp
    let persistence = WatchAccountFencedJSONStore<Payload>(
      location: .file(rootURL.appendingPathComponent("progress.json")), accountStamp: accountStamp)
    self.persistence = persistence
    self.now = now

    do {
      if let envelope = try persistence.load() {
        // A row that cannot be trusted is dropped on its own: refusing the whole file would
        // fail every later launch and sign-in for this account.
        var restored: [UUID: WatchOfflineProgressSession] = [:]
        for session in envelope.sessions
        where restored[session.id] == nil && session.accountStamp == accountStamp && Self.validPersisted(session) {
          restored[session.id] = session
        }
        self.sessionsByID = restored
        // A process death cannot prove that an upload was sent. Requeue every inflight session.
        self.inFlightIDs = []
        if envelope.inFlightIDs.isEmpty == false || restored.count != envelope.sessions.count {
          try persistence.save(Payload(sessions: Array(restored.values), inFlightIDs: []))
        }
      } else {
        self.sessionsByID = [:]
        self.inFlightIDs = []
        // Initial creation historically propagates the underlying write error.
        do {
          try persistence.save(Payload(sessions: [], inFlightIDs: []))
        } catch WatchFencedStoreError.io(let error) {
          throw error
        }
      }
    } catch let error as WatchFencedStoreError {
      switch error {
      case .corrupt, .versionMismatch:
        // This build cannot read the file, but another build may: it is set aside, not
        // overwritten, and the account starts empty so it stays usable.
        let file = rootURL.appendingPathComponent("progress.json")
        let aside = rootURL.appendingPathComponent("progress.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        self.sessionsByID = [:]
        self.inFlightIDs = []
        do {
          try persistence.save(Payload(sessions: [], inFlightIDs: []))
        } catch { throw WatchOfflineProgressStoreError.storageFailure }
      case .io: throw WatchOfflineProgressStoreError.storageFailure
      case .foreignAccount: throw WatchOfflineProgressStoreError.accountMismatch
      }
    }
  }

  public func allSessions() -> [WatchOfflineProgressSession] {
    sessionsByID.values.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  public func session(id: UUID) -> WatchOfflineProgressSession? {
    sessionsByID[id]
  }

  public func isUploadInFlight(id: UUID) -> Bool {
    inFlightIDs.contains(id)
  }

  @discardableResult
  public func startSession(
    selection: WatchSelection,
    startPosition: Double? = nil,
    duration: Double? = nil,
    lastKnownSharedPosition: Double? = nil,
    lastKnownSharedObservedAt: Date? = nil,
    id: UUID = UUID()
  ) throws -> WatchOfflineProgressSession {
    try validate(
      selection: selection, startPosition: startPosition, duration: duration,
      lastKnownSharedPosition: lastKnownSharedPosition,
      lastKnownSharedObservedAt: lastKnownSharedObservedAt)
    guard sessionsByID[id] == nil else { throw WatchOfflineProgressStoreError.duplicate(id) }
    let timestamp = now()
    let position = startPosition ?? 0
    let session = WatchOfflineProgressSession(
      id: id, accountStamp: accountStamp, selection: selection,
      startedAt: timestamp, updatedAt: timestamp, startPosition: startPosition,
      currentPosition: position, duration: duration, timeListening: 0, isFinished: false,
      lastKnownSharedPosition: lastKnownSharedPosition,
      lastKnownSharedObservedAt: lastKnownSharedObservedAt)
    sessionsByID[id] = session
    try persist()
    return session
  }

  @discardableResult
  public func recordProgress(
    sessionID: UUID,
    currentPosition: Double,
    listenedDelta: Double,
    isFinished: Bool = false,
    userSeek: Bool = false
  ) throws -> WatchOfflineProgressSession {
    guard currentPosition.isFinite, currentPosition >= 0 else {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
    guard listenedDelta.isFinite, listenedDelta >= 0 else {
      throw WatchOfflineProgressStoreError.invalidDelta
    }
    var session = try existing(sessionID)
    if let duration = session.duration, currentPosition > duration {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
    let totalListening = session.timeListening + listenedDelta
    guard totalListening.isFinite else {
      throw WatchOfflineProgressStoreError.invalidDelta
    }
    session.currentPosition = currentPosition
    session.timeListening = totalListening
    session.isFinished = session.isFinished || isFinished
    let timestamp = now()
    session.updatedAt = timestamp
    if listenedDelta > 0 || userSeek { session.lastListenedAt = timestamp }
    let previous = sessionsByID[sessionID]
    let previousRevision = revisions[sessionID]
    sessionsByID[sessionID] = session
    revisions[sessionID, default: 0] += 1
    do {
      try persist()
    } catch {
      // A write that throws applied nothing, so a caller that carries the delta forward and
      // sends it again does not count it twice.
      sessionsByID[sessionID] = previous
      revisions[sessionID] = previousRevision
      throw error
    }
    return session
  }

  /// The audio ran past the row's declared duration. A shorter value is ignored.
  public func growDuration(sessionID: UUID, to duration: Double) throws {
    guard duration.isFinite, duration > 0 else { throw WatchOfflineProgressStoreError.invalidPosition }
    var session = try existing(sessionID)
    guard let current = session.duration, duration > current else { return }
    session.duration = duration
    sessionsByID[sessionID] = session
    revisions[sessionID, default: 0] += 1
    try persist()
  }

  @discardableResult
  public func finish(sessionID: UUID, currentPosition: Double, listenedDelta: Double = 0) throws
    -> WatchOfflineProgressSession
  {
    try recordProgress(
      sessionID: sessionID, currentPosition: currentPosition, listenedDelta: listenedDelta,
      isFinished: true)
  }

  /// Reserves at most one batch. Calling this again before acknowledgement returns no rows, so a
  /// retry cannot create overlapping local-session requests for the same UUIDs.
  /// Writes `plan`'s positions to their rows and returns the rows that may upload. Each rewrite
  /// stands alone: a row that cannot take its position keeps its own, waits, and does not
  /// stop the rest of the batch.
  public func apply(_ plan: WatchOfflineReconciliationPlan) -> Set<UUID> {
    var eligible: Set<UUID> = []
    for decision in plan.decisions {
      guard let row = session(id: decision.sessionID) else { continue }
      if row.currentPosition != decision.position || decision.needsFreshTimestamp {
        do {
          try recordProgress(sessionID: decision.sessionID, currentPosition: decision.position, listenedDelta: 0)
        } catch { continue }
      }
      eligible.insert(decision.sessionID)
    }
    return eligible
  }

  public func pendingUploadBatch(limit: Int = 50, eligibleIDs: Set<UUID>? = nil) throws -> [LocalPlaybackSession] {
    guard limit > 0, limit <= Self.maximumUploadBatchSize else {
      throw WatchOfflineProgressStoreError.batchSizeExceeded
    }
    guard inFlightIDs.isEmpty else { throw WatchOfflineProgressStoreError.uploadAlreadyInFlight }
    let selected = allSessions()
      .filter { (eligibleIDs?.contains($0.id) ?? true) && $0.hasProgressToSend }
      .prefix(limit)
    let sessions = Array(selected)
    inFlightIDs = Set(sessions.map(\.id))
    reservedSnapshots = Dictionary(
      uniqueKeysWithValues: sessions.map {
        ($0.id, ReservedSnapshot(revision: revisions[$0.id, default: 0], session: $0))
      })
    try persist()
    return sessions.map { $0.toUpload() }
  }

  /// Removes only sessions explicitly acknowledged by the server. Failed or missing rows remain
  /// queued, and every inflight reservation is released for a later retry.
  ///
  /// A row written to after its batch was reserved was acknowledged for its reserved values only.
  /// Its remainder moves to a new row instead of being re-sent under the acknowledged UUID, because
  /// `timeListening` is a session total and the server's handling of a repeated UUID is unproven.
  /// Returns each such old row ID mapped to its replacement.
  @discardableResult
  public func acknowledge(_ outcome: LocalSessionSyncOutcome) throws -> [UUID: UUID] {
    let acknowledgedIDs = outcome.acknowledged
    let successful = inFlightIDs.filter { acknowledgedIDs.contains($0.uuidString.lowercased()) }
    var remap: [UUID: UUID] = [:]
    for id in successful {
      guard let current = sessionsByID.removeValue(forKey: id) else { continue }
      let revision = revisions.removeValue(forKey: id) ?? 0
      guard let snapshot = reservedSnapshots[id], snapshot.revision != revision else { continue }
      let remainder = Self.remainder(of: current, after: snapshot.session)
      sessionsByID[remainder.id] = remainder
      revisions[remainder.id] = 1
      remap[id] = remainder.id
    }
    inFlightIDs.removeAll()
    reservedSnapshots.removeAll()
    try persist()
    return remap
  }

  /// Releases a local reservation after a transport failure without deleting any progress.
  public func releaseUploadBatch() throws {
    inFlightIDs.removeAll()
    reservedSnapshots.removeAll()
    try persist()
  }

  public func delete(sessionID: UUID) throws {
    guard sessionsByID.removeValue(forKey: sessionID) != nil else {
      throw WatchOfflineProgressStoreError.notFound(sessionID)
    }
    inFlightIDs.remove(sessionID)
    revisions.removeValue(forKey: sessionID)
    reservedSnapshots.removeValue(forKey: sessionID)
    try persist()
  }

  private static func remainder(
    of current: WatchOfflineProgressSession, after sent: WatchOfflineProgressSession
  ) -> WatchOfflineProgressSession {
    WatchOfflineProgressSession(
      id: UUID(), accountStamp: current.accountStamp, selection: current.selection,
      startedAt: sent.updatedAt, updatedAt: current.updatedAt, startPosition: sent.currentPosition,
      currentPosition: current.currentPosition, duration: current.duration,
      timeListening: max(0, current.timeListening - sent.timeListening), isFinished: current.isFinished,
      lastKnownSharedPosition: current.lastKnownSharedPosition,
      lastKnownSharedObservedAt: current.lastKnownSharedObservedAt, lastListenedAt: current.lastListenedAt)
  }

  private func existing(_ id: UUID) throws -> WatchOfflineProgressSession {
    guard let session = sessionsByID[id] else {
      throw WatchOfflineProgressStoreError.notFound(id)
    }
    guard session.accountStamp == accountStamp else {
      throw WatchOfflineProgressStoreError.accountMismatch
    }
    return session
  }

  private func validate(
    selection: WatchSelection,
    startPosition: Double?,
    duration: Double?,
    lastKnownSharedPosition: Double?,
    lastKnownSharedObservedAt: Date?
  ) throws {
    guard case .audiobookshelf(let itemID, let episodeID) = selection else {
      throw WatchOfflineProgressStoreError.nativeSelection
    }
    guard Self.validIdentifier(itemID), episodeID.map(Self.validIdentifier) ?? true else {
      throw WatchOfflineProgressStoreError.invalidSelection
    }
    if let startPosition, startPosition.isFinite == false || startPosition < 0 {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
    if let duration, duration.isFinite == false || duration <= 0 {
      throw WatchOfflineProgressStoreError.invalidDuration
    }
    if let startPosition, let duration, startPosition > duration {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
    if let lastKnownSharedPosition,
      lastKnownSharedPosition.isFinite == false || lastKnownSharedPosition < 0
    {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
    if let lastKnownSharedObservedAt,
      lastKnownSharedObservedAt.timeIntervalSinceReferenceDate.isFinite == false
    {
      throw WatchOfflineProgressStoreError.invalidPosition
    }
  }

  private func persist() throws {
    do {
      try persistence.save(Payload(sessions: allSessions(), inFlightIDs: Array(inFlightIDs)))
    } catch {
      throw WatchOfflineProgressStoreError.storageFailure
    }
  }

  private static func validIdentifier(_ value: String) -> Bool {
    guard value.isEmpty == false, value.utf8.count <= 512,
      value.contains("://") == false, value.lowercased().hasPrefix("file:") == false,
      value.hasPrefix("/") == false, value.contains("/") == false,
      value.contains("\\") == false, value.contains("..") == false,
      value.contains("?") == false, value.contains("#") == false
    else { return false }
    return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }

  private static func validPersisted(_ session: WatchOfflineProgressSession) -> Bool {
    guard case .audiobookshelf(let itemID, let episodeID) = session.selection,
      validIdentifier(itemID), episodeID.map(validIdentifier) ?? true,
      session.startedAt.timeIntervalSinceReferenceDate.isFinite,
      session.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      session.startPosition.map({ $0.isFinite && $0 >= 0 }) ?? true,
      session.currentPosition.isFinite, session.currentPosition >= 0,
      session.duration.map({ $0.isFinite && $0 > 0 }) ?? true,
      session.timeListening.isFinite, session.timeListening >= 0,
      session.lastKnownSharedPosition.map({ $0.isFinite && $0 >= 0 }) ?? true,
      session.lastKnownSharedObservedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
      session.lastListenedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true
    else { return false }
    return true
  }

  private static func excludeFromBackup(_ url: URL) {
    #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableURL = url
      try? mutableURL.setResourceValues(values)
    #endif
  }

  private static func protectPrivateFile(_ url: URL) {
    #if os(iOS) || os(tvOS) || os(watchOS)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    #endif
  }
}
