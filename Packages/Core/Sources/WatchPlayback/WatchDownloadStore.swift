import CryptoKit
import Foundation
import PlayerCore
import WatchProtocol

/// Durable, account-scoped storage for Watch-owned Audiobookshelf downloads. Transfer scheduling
/// remains outside this actor; the background adapter attaches its opaque task id and hands over a
/// temporary file only after the transfer has finished.
public actor WatchDownloadStore {
  public let rootURL: URL
  public let accountStamp: WatchAccountStamp
  public private(set) var networkPolicy: WatchDownloadNetworkPolicy
  public let storageQuotaBytes: Int64

  private let persistence: WatchAccountFencedJSONStore<Payload>
  private let vault: WatchDownloadFileVault
  /// Shared with the received-episode store. `nil` keeps this store's accounting exactly as it was
  /// before the two stores shared a ceiling.
  private let storageBudget: WatchStorageBudget?
  private let now: @Sendable () -> Date
  var manifestsByID: [UUID: WatchDownloadManifest]
  /// Last state known to be on disk. A failed write restores it so memory never runs ahead.
  private var persistedManifests: [UUID: WatchDownloadManifest] = [:]
  private var persistedNetworkPolicy: WatchDownloadNetworkPolicy
  private var persistedProgress: [UUID: (bytes: Int64, at: Date)] = [:]

  struct Payload: Codable, Sendable {
    var networkPolicy: WatchDownloadNetworkPolicy
    let storageQuotaBytes: Int64
    var manifests: [WatchDownloadManifest]
  }

  public init(
    rootURL: URL,
    accountStamp: WatchAccountStamp,
    networkPolicy: WatchDownloadNetworkPolicy = .wifiOnly,
    storageQuotaBytes: Int64 = 2_000_000_000,
    now: @escaping @Sendable () -> Date = Date.init,
    storageBudget: WatchStorageBudget? = nil
  ) throws {
    guard storageQuotaBytes > 0 else { throw WatchDownloadStoreError.invalidExpectedBytes }
    let vault = try WatchDownloadFileVault(rootURL: rootURL)

    self.rootURL = rootURL
    self.accountStamp = accountStamp
    self.networkPolicy = networkPolicy
    self.persistedNetworkPolicy = networkPolicy
    self.storageQuotaBytes = storageQuotaBytes
    self.storageBudget = storageBudget
    let persistence = WatchAccountFencedJSONStore<Payload>(
      location: .file(rootURL.appendingPathComponent("manifest.json")), accountStamp: accountStamp)
    self.persistence = persistence
    self.vault = vault
    self.now = now

    do {
      let opened = try Self.open(
        persistence: persistence, rootURL: rootURL, vault: vault, accountStamp: accountStamp,
        networkPolicy: networkPolicy, storageQuotaBytes: storageQuotaBytes)
      self.networkPolicy = opened.networkPolicy
      self.persistedNetworkPolicy = opened.networkPolicy
      self.manifestsByID = opened.manifests
      self.persistedManifests = opened.manifests
      // No install can be running before the store exists, so any `.part` file is a crash leftover.
      vault.removeStagingFiles()
      // A nonisolated initializer cannot call the actor's isolated helpers, so record what the
      // loaded manifests reserve directly.
      storageBudget?.record(Self.reservation(of: opened.manifests), for: .audiobookshelf)
    } catch let error as WatchFencedStoreError {
      switch error {
      case .corrupt, .versionMismatch, .io: throw WatchDownloadStoreError.storageFailure
      case .foreignAccount: throw WatchDownloadStoreError.accountMismatch
      }
    }
  }

  public func allManifests() -> [WatchDownloadManifest] {
    manifestsByID.values.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  public func manifest(id: UUID) -> WatchDownloadManifest? {
    manifestsByID[id]
  }

  /// True only when every file in a planned group has a verified completed manifest. A partial
  /// enqueue therefore cannot make an item appear offline-playable.
  public func isGroupComplete(groupID downloadGroupID: String) -> Bool {
    guard downloadGroupID.isEmpty == false else { return false }
    let rows = manifestsByID.values.filter { $0.downloadGroupID == downloadGroupID }
    guard let expected = rows.first?.expectedTrackCount,
      expected > 0, rows.count == expected,
      rows.allSatisfy({ $0.expectedTrackCount == expected && $0.state == .completed })
    else { return false }
    guard Set(rows.map(\.fileIndex)).count == expected else { return false }
    return rows.allSatisfy { row in
      (try? completedFileURL(for: row.id)) != nil
    }
  }

  public func setNetworkPolicy(_ policy: WatchDownloadNetworkPolicy) throws {
    networkPolicy = policy
    try persist()
  }

  /// Returns the same relative destination for the same account, source, file id and file index.
  /// It contains only a digest and a MIME-derived extension, so server identifiers never become
  /// path components and traversal/symlink tricks cannot enter the manifest.
  public static func destinationRelativePath(
    accountStamp: WatchAccountStamp,
    selection: WatchSelection,
    fileID: String,
    fileIndex: Int,
    expectedMIMEType: String
  ) -> String {
    let selectionMaterial: String
    switch selection {
    case .audiobookshelf(let itemID, let episodeID):
      selectionMaterial = "abs\u{1F}\(itemID)\u{1F}\(episodeID ?? "")"
    case .nativeFeed(let feedID, let episodeID):
      selectionMaterial = "rss\u{1F}\(feedID)\u{1F}\(episodeID)"
    }
    let material =
      "\(accountStamp.accountIdentityHash)\u{1F}\(accountStamp.serverIdentityHash)\u{1F}\(selectionMaterial)\u{1F}\(fileID)\u{1F}\(fileIndex)"
    let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(digest)-\(fileIndex).\(fileExtension(for: expectedMIMEType))"
  }

  @discardableResult
  public func enqueue(
    selection: WatchSelection,
    downloadGroupID: String = "",
    expectedTrackCount: Int = 1,
    fileID: String,
    fileIndex: Int = 0,
    startOffset: Double = 0,
    duration: Double? = nil,
    expectedBytes: Int64? = nil,
    expectedMIMEType: String,
    id: UUID = UUID(),
    chapters: [PlayerCore.PlaybackChapter] = [],
    origin: WatchABSOrigin = .watch,
    phoneRevision: UInt64? = nil
  ) throws -> WatchDownloadManifest {
    try validate(
      selection: selection, fileID: fileID, fileIndex: fileIndex,
      downloadGroupID: downloadGroupID, expectedTrackCount: expectedTrackCount,
      startOffset: startOffset, duration: duration, expectedBytes: expectedBytes,
      expectedMIMEType: expectedMIMEType)
    guard manifestsByID[id] == nil else { throw WatchDownloadStoreError.duplicateDownload }
    guard
      manifestsByID.values.contains(where: {
        $0.selection == selection && $0.fileID == fileID && $0.fileIndex == fileIndex
      }) == false
    else { throw WatchDownloadStoreError.duplicateDownload }
    try ensureQuota(forAdditionalBytes: expectedBytes ?? 0)
    let timestamp = now()
    let manifest = WatchDownloadManifest(
      id: id, accountStamp: accountStamp, selection: selection,
      downloadGroupID: downloadGroupID.isEmpty ? id.uuidString.lowercased() : downloadGroupID,
      expectedTrackCount: expectedTrackCount, fileID: fileID,
      fileIndex: fileIndex, startOffset: startOffset, duration: duration,
      expectedBytes: expectedBytes, expectedMIMEType: expectedMIMEType,
      destinationRelativePath: Self.destinationRelativePath(
        accountStamp: accountStamp, selection: selection, fileID: fileID,
        fileIndex: fileIndex, expectedMIMEType: expectedMIMEType),
      createdAt: timestamp, updatedAt: timestamp, chapters: chapters, origin: origin, phoneRevision: phoneRevision)
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  @discardableResult
  public func beginTransfer(id: UUID, isWiFiAvailable: Bool) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state == .queued else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .downloading)
    }
    if networkPolicy == .wifiOnly && isWiFiAvailable == false {
      manifest.failureReason = .waitingForWiFi
      manifest.updatedAt = now()
      manifestsByID[id] = manifest
      try persist()
      return manifest
    }
    manifest.state = .downloading
    manifest.failureReason = nil
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  @discardableResult
  public func attachTransfer(taskIdentifier: String, to id: UUID) throws -> WatchDownloadManifest {
    guard Self.validIdentifier(taskIdentifier) else { throw WatchDownloadStoreError.invalidFileIdentity }
    var manifest = try existing(id)
    guard manifest.state == .queued || manifest.state == .downloading || manifest.state == .paused else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, manifest.state)
    }
    manifest.transferTaskIdentifier = taskIdentifier
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  @discardableResult
  public func recordTransferProgress(_ update: WatchDownloadTransferUpdate, for id: UUID) throws
    -> WatchDownloadManifest
  {
    guard update.receivedBytes >= 0,
      update.expectedBytes.map({ $0 >= 0 }) ?? true
    else { throw WatchDownloadStoreError.invalidExpectedBytes }
    var manifest = try existing(id)
    guard manifest.state == .downloading else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .downloading)
    }
    if let expected = manifest.expectedBytes, update.receivedBytes > expected {
      throw WatchDownloadStoreError.fileSizeMismatch
    }
    if let expected = update.expectedBytes, expected != manifest.expectedBytes {
      throw WatchDownloadStoreError.fileSizeMismatch
    }
    manifest.receivedBytes = update.receivedBytes
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    // Byte counts are advisory and recomputed by the transport, so they reach disk only after a
    // coarse step; state changes persist them as a side effect.
    let last =
      persistedProgress[id]
      ?? (bytes: persistedManifests[id]?.receivedBytes ?? 0, at: persistedManifests[id]?.updatedAt ?? .distantPast)
    let step = manifest.progressStep
    if update.receivedBytes < last.bytes || update.receivedBytes - last.bytes >= step
      || manifest.updatedAt.timeIntervalSince(last.at) >= 30
    {
      try persist()
      persistedProgress[id] = (update.receivedBytes, manifest.updatedAt)
    }
    return manifest
  }

  @discardableResult
  public func pause(id: UUID) throws -> WatchDownloadManifest {
    try transition(id: id, to: .paused, reason: nil)
  }

  @discardableResult
  public func resume(id: UUID) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state == .paused else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .queued)
    }
    manifest.state = .queued
    manifest.failureReason = nil
    manifest.transferTaskIdentifier = nil
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  @discardableResult
  public func retry(id: UUID) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state == .failed else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .queued)
    }
    manifest.state = .queued
    manifest.failureReason = nil
    manifest.receivedBytes = 0
    manifest.transferTaskIdentifier = nil
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  @discardableResult
  public func fail(id: UUID, reason: WatchDownloadFailureReason) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state != .completed else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .failed)
    }
    manifest.state = .failed
    manifest.failureReason = reason
    manifest.transferTaskIdentifier = nil
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  /// Verifies and atomically installs a completed temporary file. The manifest becomes playable
  /// only after the destination exists and its measured byte count matches the expectation.
  @discardableResult
  public func commitDownloadedTemporaryFile(
    _ temporaryFileURL: URL,
    for id: UUID,
    responseBytes: Int64? = nil
  ) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state == .downloading || manifest.state == .queued else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, .completed)
    }
    let measured = try vault.measuredTemporaryFile(
      temporaryFileURL, expectedBytes: manifest.expectedBytes, responseBytes: responseBytes)
    try ensureQuotaReplacing(id: id, with: measured)
    do {
      try vault.install(temporaryFileURL, relativePath: manifest.destinationRelativePath, measured: measured)
    } catch {
      // The budget was claimed for the new total but the install changed nothing, so put the
      // ledger back where the manifests say it should be before reporting the failure.
      recordReservation()
      throw error
    }
    manifest.state = .completed
    manifest.receivedBytes = measured
    manifest.failureReason = nil
    manifest.transferTaskIdentifier = nil
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    // The file is installed whatever the write says, so memory keeps the completed row.
    try persist(rollingBack: false)
    return manifest
  }

  public func completedFileURL(for id: UUID) throws -> URL {
    let manifest = try existing(id)
    guard manifest.state == .completed else { throw WatchDownloadStoreError.completedFileMissing }
    return try vault.completedFile(
      relativePath: manifest.destinationRelativePath, expectedBytes: manifest.expectedBytes)
  }

  /// Destination used by a background adapter that wants to preserve a finished file before its
  /// delegate callback returns. This is a local URL only; it is never part of a manifest payload.
  public func destinationFileURL(for id: UUID) throws -> URL {
    let manifest = try existing(id)
    return try vault.destinationFile(relativePath: manifest.destinationRelativePath)
  }

  public func delete(id: UUID) throws {
    let manifest = try existing(id)
    try vault.remove(relativePath: manifest.destinationRelativePath)
    manifestsByID.removeValue(forKey: id)
    // The file is gone whatever the write says, so memory does not bring the row back.
    try persist(rollingBack: false)
  }

  /// A launch recovery pass makes any transfer that was downloading at the previous checkpoint
  /// retryable, never playable. Partial staging files are also removed.
  @discardableResult
  public func recoverInterruptedTransfers() throws -> [WatchDownloadManifest] {
    var changed = false
    for id in manifestsByID.keys {
      guard var manifest = manifestsByID[id], manifest.state == .downloading else { continue }
      manifest.state = .failed
      manifest.failureReason = .interrupted
      manifest.transferTaskIdentifier = nil
      manifest.updatedAt = now()
      manifestsByID[id] = manifest
      changed = true
    }
    vault.removeStagingFiles()
    if changed { try persist() }
    return allManifests()
  }

  private func transition(
    id: UUID, to state: WatchDownloadState, reason: WatchDownloadFailureReason?
  ) throws -> WatchDownloadManifest {
    var manifest = try existing(id)
    guard manifest.state == .downloading && state == .paused else {
      throw WatchDownloadStoreError.illegalTransition(manifest.state, state)
    }
    manifest.state = state
    manifest.failureReason = reason
    manifest.updatedAt = now()
    manifestsByID[id] = manifest
    try persist()
    return manifest
  }

  private func existing(_ id: UUID) throws -> WatchDownloadManifest {
    guard let manifest = manifestsByID[id] else { throw WatchDownloadStoreError.notFound(id) }
    guard manifest.accountStamp == accountStamp else { throw WatchDownloadStoreError.accountMismatch }
    return manifest
  }

  private func validate(
    selection: WatchSelection, fileID: String, fileIndex: Int,
    downloadGroupID: String, expectedTrackCount: Int, startOffset: Double,
    duration: Double?, expectedBytes: Int64?, expectedMIMEType: String
  ) throws {
    guard case .audiobookshelf(let itemID, let episodeID) = selection else {
      throw WatchDownloadStoreError.nativeSelection
    }
    guard Self.validIdentifier(itemID), episodeID.map(Self.validIdentifier) ?? true else {
      throw WatchDownloadStoreError.invalidSelection
    }
    guard Self.validIdentifier(fileID) else { throw WatchDownloadStoreError.invalidFileIdentity }
    guard fileIndex >= 0 else { throw WatchDownloadStoreError.invalidFileIndex }
    guard startOffset.isFinite, startOffset >= 0 else { throw WatchDownloadStoreError.invalidPosition }
    if let duration, !WatchDownloadValidation.validDuration(duration) {
      throw WatchDownloadStoreError.invalidDuration
    }
    if let expectedBytes, !WatchDownloadValidation.validSize(expectedBytes) {
      throw WatchDownloadStoreError.invalidExpectedBytes
    }
    guard Self.validMIMEType(expectedMIMEType) else { throw WatchDownloadStoreError.invalidMIMEType }
    guard expectedTrackCount > 0, expectedTrackCount <= 128 else {
      throw WatchDownloadStoreError.invalidFileIndex
    }
    if downloadGroupID.isEmpty == false, Self.validIdentifier(downloadGroupID) == false {
      throw WatchDownloadStoreError.invalidSelection
    }
  }

  /// Reads the manifest payload, restores the rows it can express, and writes the initial payload
  /// when nothing readable existed. The initializer maps the persistence errors; an error from the
  /// initial write propagates as it always has.
  private static func open(
    persistence: WatchAccountFencedJSONStore<Payload>, rootURL: URL, vault: WatchDownloadFileVault,
    accountStamp: WatchAccountStamp, networkPolicy: WatchDownloadNetworkPolicy,
    storageQuotaBytes: Int64
  ) throws -> (networkPolicy: WatchDownloadNetworkPolicy, manifests: [UUID: WatchDownloadManifest]) {
    var loaded: Payload?
    var needsRewrite = false
    do { loaded = try persistence.load() } catch WatchFencedStoreError.corrupt {
      needsRewrite = true
    } catch WatchFencedStoreError.versionMismatch {
      needsRewrite = true
    }

    if let decoded = loaded {
      guard decoded.storageQuotaBytes == storageQuotaBytes else {
        throw WatchDownloadStoreError.accountMismatch
      }
      let restored = restore(decoded, accountStamp: accountStamp)
      if restored.droppedRows {
        try? persistence.save(
          Payload(
            networkPolicy: decoded.networkPolicy, storageQuotaBytes: storageQuotaBytes,
            manifests: restored.manifests.values.sorted { $0.id.uuidString < $1.id.uuidString }))
      }
      return (networkPolicy: decoded.networkPolicy, manifests: restored.manifests)
    }

    if needsRewrite {
      // This build cannot read the manifest, so it cannot say which files it owns: the manifest is
      // set aside for a build that can, and the files go so none are orphaned.
      let aside = rootURL.appendingPathComponent("manifest.unreadable.json")
      try? FileManager.default.removeItem(at: aside)
      try? FileManager.default.moveItem(at: rootURL.appendingPathComponent("manifest.json"), to: aside)
      vault.removeAllFiles()
    }
    // Initial creation historically propagates the underlying write error.
    do {
      try persistence.save(
        Payload(networkPolicy: networkPolicy, storageQuotaBytes: storageQuotaBytes, manifests: []))
    } catch WatchFencedStoreError.io(let error) {
      throw error
    }
    return (networkPolicy: networkPolicy, manifests: [:])
  }

  private static func restore(
    _ payload: Payload, accountStamp: WatchAccountStamp
  ) -> (manifests: [UUID: WatchDownloadManifest], droppedRows: Bool) {
    // One invalid or duplicated row must not make the whole store unreadable on every launch.
    var restored: [UUID: WatchDownloadManifest] = [:]
    var droppedRows = false
    for manifest in payload.manifests {
      guard restored[manifest.id] == nil, validatePersisted(manifest, accountStamp: accountStamp)
      else {
        droppedRows = true
        continue
      }
      restored[manifest.id] = manifest
    }
    return (manifests: restored, droppedRows: droppedRows)
  }

  private static func validatePersisted(
    _ manifest: WatchDownloadManifest,
    accountStamp: WatchAccountStamp
  ) -> Bool {
    guard manifest.accountStamp == accountStamp,
      case .audiobookshelf(let itemID, let episodeID) = manifest.selection,
      validIdentifier(itemID), episodeID.map(validIdentifier) ?? true,
      validIdentifier(manifest.fileID), manifest.fileIndex >= 0,
      manifest.startOffset.isFinite, manifest.startOffset >= 0,
      manifest.duration.map(WatchDownloadValidation.validDuration) ?? true,
      manifest.expectedBytes.map(WatchDownloadValidation.validSize) ?? true,
      validMIMEType(manifest.expectedMIMEType),
      manifest.expectedTrackCount > 0, manifest.expectedTrackCount <= 128,
      validIdentifier(manifest.downloadGroupID),
      manifest.receivedBytes >= 0,
      manifest.transferTaskIdentifier.map(validIdentifier) ?? true,
      manifest.destinationRelativePath
        == destinationRelativePath(
          accountStamp: accountStamp, selection: manifest.selection,
          fileID: manifest.fileID, fileIndex: manifest.fileIndex,
          expectedMIMEType: manifest.expectedMIMEType)
    else { return false }
    if let expected = manifest.expectedBytes, manifest.receivedBytes > expected { return false }
    if manifest.state == .completed && manifest.transferTaskIdentifier != nil { return false }
    if manifest.state == .completed && manifest.failureReason != nil { return false }
    if manifest.state == .failed && manifest.failureReason == nil { return false }
    return true
  }

  private func ensureQuota(forAdditionalBytes bytes: Int64) throws {
    guard bytes >= 0 else { throw WatchDownloadStoreError.invalidExpectedBytes }
    let reserved = reservedBytes
    guard reserved <= storageQuotaBytes - bytes else { throw WatchDownloadStoreError.quotaExceeded }
    try claimReservation(reserved + bytes)
  }

  private func ensureQuotaReplacing(id: UUID, with bytes: Int64) throws {
    let reserved = manifestsByID.values.reduce(Int64(0)) { partial, manifest in
      guard manifest.id != id, manifest.state != .failed else { return partial }
      return partial + (manifest.expectedBytes ?? 0)
    }
    guard bytes >= 0, reserved <= storageQuotaBytes - bytes else {
      throw WatchDownloadStoreError.quotaExceeded
    }
    try claimReservation(reserved + bytes)
  }

  /// The store's own reservation, defined exactly as `ensureQuota` defines it: expected bytes of
  /// every manifest that is not failed. Failed rows own no bytes and hold no budget.
  private var reservedBytes: Int64 {
    Self.reservation(of: manifestsByID)
  }

  private static func reservation(of manifests: [UUID: WatchDownloadManifest]) -> Int64 {
    manifests.values.reduce(Int64(0)) { partial, manifest in
      guard manifest.state != .failed else { return partial }
      return partial + (manifest.expectedBytes ?? 0)
    }
  }

  private func claimReservation(_ bytes: Int64) throws {
    guard let storageBudget else { return }
    guard storageBudget.claim(bytes, for: .audiobookshelf) else {
      throw WatchDownloadStoreError.quotaExceeded
    }
  }

  private func recordReservation() {
    storageBudget?.record(reservedBytes, for: .audiobookshelf)
  }

  func persist(rollingBack: Bool = true) throws {
    do {
      try persistence.save(
        Payload(networkPolicy: networkPolicy, storageQuotaBytes: storageQuotaBytes, manifests: allManifests()))
      persistedManifests = manifestsByID
      persistedNetworkPolicy = networkPolicy
    } catch {
      if rollingBack {
        manifestsByID = persistedManifests
        networkPolicy = persistedNetworkPolicy
      }
      recordReservation()
      throw WatchDownloadStoreError.storageFailure
    }
    recordReservation()
  }

  private static func validMIMEType(_ value: String) -> Bool {
    let supported = [
      "audio/mpeg", "audio/mp3", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/flac", "audio/x-flac",
      "audio/ogg", "audio/wav", "audio/x-wav", "audio/aiff", "audio/x-aiff",
    ]
    return supported.contains(value.lowercased())
  }

  private static func validIdentifier(_ value: String) -> Bool {
    WatchDownloadValidation.validIdentifier(value, rejectsFileScheme: true)
  }

  static func fileExtension(for mime: String) -> String {
    let base = mime.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
    switch base {
    case "audio/mpeg": return "mp3"
    case "audio/mp4", "audio/x-m4a": return "m4a"
    case "audio/aac": return "aac"
    case "audio/ogg": return "ogg"
    default: return "audio"
    }
  }

}
