import CryptoKit
import Foundation
import WatchProtocol

/// Durable, account-scoped storage for native-RSS episodes the iPhone offers to the Watch. The
/// store owns its inventory and reservations; the phone owns the desired set. The Watch downloads
/// each episode's enclosure itself and commits the file here through the reservation taken at
/// offer time (ADR 0020). Files live in the same vault as Audiobookshelf downloads, and
/// `WatchStorageBudget` is the one ceiling both stores claim against.
///
/// Persistence is a `WatchAccountFencedJSONStore` in `rootURL`, so an account's copies never appear
/// under another account's stamp. Received copies are a re-sendable cache: an unreadable payload or
/// a foreign stamp starts empty and the phone offers the set again. A row that cannot be expressed
/// after the move from A's file transport is dropped on its own, with its file, rather than taking
/// the whole store with it.
public actor WatchReceivedEpisodeStore {
  public let rootURL: URL
  public let accountStamp: WatchAccountStamp
  public let installID: String
  public private(set) var appliedGeneration: UInt64

  private struct Payload: Codable, Sendable {
    var appliedGeneration: UInt64
    var entries: [WatchReceivedEpisode]
    /// Rows the lossy decode below refused. Persisted as nothing; used only to decide a rewrite.
    var droppedEntryCount = 0

    init(appliedGeneration: UInt64, entries: [WatchReceivedEpisode]) {
      self.appliedGeneration = appliedGeneration
      self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case appliedGeneration, entries }

    private struct LossyEntry: Decodable {
      let entry: WatchReceivedEpisode?

      init(from decoder: Decoder) throws {
        entry = try? WatchReceivedEpisode(from: decoder)
      }
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      appliedGeneration = try container.decode(UInt64.self, forKey: .appliedGeneration)
      let decoded = try container.decode([LossyEntry].self, forKey: .entries)
      entries = decoded.compactMap(\.entry)
      droppedEntryCount = decoded.count - entries.count
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(appliedGeneration, forKey: .appliedGeneration)
      try container.encode(entries, forKey: .entries)
    }
  }

  private let persistence: WatchAccountFencedJSONStore<Payload>
  private let vault: WatchDownloadFileVault
  private let budget: WatchStorageBudget
  private let now: @Sendable () -> Date
  private var entriesBySelection: [WatchNativeSelection: WatchReceivedEpisode]
  /// Last state known to be on disk. A failed write restores it so memory never runs ahead.
  private var persistedEntries: [WatchNativeSelection: WatchReceivedEpisode]
  private var persistedGeneration: UInt64

  public init(
    rootURL: URL,
    accountStamp: WatchAccountStamp,
    installID: String,
    budget: WatchStorageBudget,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    do { try WatchInstallIdentity.validate(installID) } catch {
      throw WatchReceivedEpisodeStoreError.invalidInstallIdentity
    }
    let vault: WatchDownloadFileVault
    do { vault = try WatchDownloadFileVault(rootURL: rootURL) } catch {
      throw WatchReceivedEpisodeStoreError.storageFailure
    }

    self.rootURL = rootURL
    self.accountStamp = accountStamp
    self.installID = installID
    self.vault = vault
    self.budget = budget
    self.now = now
    let persistence = WatchAccountFencedJSONStore<Payload>(
      location: .file(rootURL.appendingPathComponent("received.json")), accountStamp: accountStamp)
    self.persistence = persistence

    let opened = try Self.open(persistence: persistence, accountStamp: accountStamp)
    self.entriesBySelection = opened.entries
    self.persistedEntries = opened.entries
    self.appliedGeneration = opened.generation
    self.persistedGeneration = opened.generation

    vault.removeStagingFiles()
    // A crash between a persisted drop and its file delete leaves an unreferenced file. Only ready
    // entries own a file: a drop the store did not finish is re-offered by the phone.
    let keeping = Set(opened.entries.values.filter { $0.state == .ready }.map(\.relativePath))
    Self.removeOrphanedFiles(vault: vault, rootURL: rootURL, keeping: keeping)
    budget.record(Self.reservation(of: opened.entries), for: .receivedEpisodes)
  }

  /// Newest offer first; the tie-break is stable so inventory rows do not reorder between reads.
  public func entries() -> [WatchReceivedEpisode] {
    Self.sorted(entriesBySelection)
  }

  public func entry(for selection: WatchNativeSelection) -> WatchReceivedEpisode? {
    entriesBySelection[selection]
  }

  /// `receiving`, `downloading` and `waitingForNetwork` entries reserve their admission estimate;
  /// `ready` entries reserve what the file measured. `failed`, `declined` and `removed` hold
  /// nothing.
  public func reservedBytes() -> Int64 {
    Self.reservation(of: entriesBySelection)
  }

  /// Entries the download driver must still act on: queued, in flight or held for the network, in
  /// the same order `entries()` reports (newest offer first).
  public func pendingDownloads() -> [WatchReceivedEpisode] {
    Self.sorted(entriesBySelection).filter {
      $0.state == .receiving || $0.state == .downloading || $0.state == .waitingForNetwork
    }
  }

  /// Applies the phone's whole desired set. Persistence happens before any file deletion, so a
  /// failed write leaves every file and the previous memory state intact.
  public func apply(_ offer: WatchEpisodeSendOffer) throws -> WatchEpisodeOfferOutcome {
    if let offeredInstall = offer.watchInstallID, offeredInstall != installID {
      return .ignored(.foreignInstall)
    }
    guard offer.generation > appliedGeneration else { return .ignored(.staleGeneration) }

    var next = entriesBySelection
    var dropped: [WatchNativeSelection] = []
    var filesToDelete: [String] = []
    let timestamp = now()

    // Any local entry the offer no longer names is dropped, tombstones included: the phone omitting
    // a removed episode is its acknowledgement. Dropping first releases those bytes, so an offer
    // that swaps old episodes for new ones on a full Watch admits the new ones.
    Self.dropAbsentEntries(offer, from: &next, dropped: &dropped, filesToDelete: &filesToDelete)
    budget.record(Self.reservation(of: next), for: .receivedEpisodes)

    let changes = Self.admitOfferedEntries(
      offer, into: &next, dropped: &dropped, filesToDelete: &filesToDelete, budget: budget,
      accountStamp: accountStamp, now: timestamp)

    appliedGeneration = offer.generation
    entriesBySelection = next
    budget.record(Self.reservation(of: next), for: .receivedEpisodes)
    try persist()

    // The write succeeded, so the old files are now unreferenced. A delete failure is retried by the
    // orphan sweep on the next launch.
    for path in filesToDelete { try? vault.remove(relativePath: path) }
    return .applied(admitted: changes.admitted, declined: changes.declined, dropped: dropped)
  }

  // MARK: Download progress

  /// Records progress for the entry's current revision. A progress value outside `0...1` (or one
  /// that is not finite) is stored as unknown rather than refusing the whole update.
  /// `responseBytes`, the response's stated length, replaces the offer's estimate; the result says
  /// whether it did, so the caller can look for a declined episode that now fits.
  @discardableResult
  public func markDownloading(
    selection: WatchNativeSelection, revision: UInt64, progress: Double?,
    responseBytes: Int64? = nil
  ) -> Bool {
    guard var entry = entriesBySelection[selection], entry.revision == revision,
      entry.state == .receiving || entry.state == .downloading || entry.state == .waitingForNetwork
    else { return false }
    let resized = responseBytes.map { entry.resize(toResponseBytes: $0) } ?? false
    entry.state = .downloading
    entry.progress = progress.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    entry.failureReason = nil
    entry.updatedAt = now()
    entriesBySelection[selection] = entry
    try? persist()
    return resized
  }

  /// Takes back episodes declined for storage that now fit, oldest offer first, and returns them.
  /// A decline is the Watch's own judgement of room at the time, often against another episode's
  /// estimate, so the phone is not made to send it again once that room exists. A decline for any
  /// other reason stands.
  public func readmitDeclined() -> [WatchNativeSelection] {
    var readmitted: [WatchNativeSelection] = []
    for entry in Self.sorted(entriesBySelection).reversed()
    where entry.state == .declined && entry.declineReason == .storageFull {
      let prospective = Self.reservation(of: entriesBySelection) + entry.reservedBytes
      guard budget.claim(prospective, for: .receivedEpisodes) else { continue }
      var queued = entry
      queued.state = .receiving
      queued.declineReason = nil
      queued.updatedAt = now()
      entriesBySelection[entry.selection] = queued
      readmitted.append(entry.selection)
    }
    guard readmitted.isEmpty == false else { return [] }
    // A failed write rolls memory back and re-records the ledger, so nothing was taken back.
    guard (try? persist()) != nil else { return [] }
    return readmitted
  }

  public func markWaitingForNetwork(selection: WatchNativeSelection, revision: UInt64) {
    guard var entry = entriesBySelection[selection], entry.revision == revision,
      entry.state == .receiving || entry.state == .downloading || entry.state == .waitingForNetwork
    else { return }
    entry.state = .waitingForNetwork
    entry.progress = nil
    entry.failureReason = nil
    entry.updatedAt = now()
    entriesBySelection[selection] = entry
    try? persist()
  }

  /// The download failed. The reservation is released: the episode is not on the Watch, and only a
  /// higher revision from the phone re-queues it ("Try Again").
  public func markFailed(
    selection: WatchNativeSelection, revision: UInt64,
    reason: WatchEpisodeInventoryEntry.FailureReason
  ) {
    guard var entry = entriesBySelection[selection], entry.revision == revision,
      entry.state != .ready, entry.state != .removed, entry.state != .declined
    else { return }
    entry.state = .failed
    entry.progress = nil
    entry.declineReason = nil
    entry.failureReason = reason
    entry.updatedAt = now()
    entriesBySelection[selection] = entry
    try? persist()
  }

  /// Installs a file the Watch downloaded for the entry's current revision. `temporaryFileURL` is
  /// consumed in every outcome. The file's measured size must equal the byte count the response was
  /// validated against; anything else is the wrong file, so the entry fails and the phone can offer
  /// it again.
  public func commitDownloadedFile(
    selection: WatchNativeSelection, revision: UInt64, temporaryFileURL: URL, acceptedBytes: Int64
  ) throws -> WatchReceivedFileOutcome {
    defer { Self.discardFile(temporaryFileURL) }
    guard let existing = entriesBySelection[selection] else { return .discarded(.unknown) }
    guard existing.revision == revision else { return .discarded(.staleRevision) }
    switch existing.state {
    case .removed: return .discarded(.removed)
    case .declined: return .discarded(.declined)
    case .ready: return .discarded(.duplicate)
    case .receiving, .downloading, .waitingForNetwork, .failed: break
    }

    let measured: Int64
    do {
      guard acceptedBytes > 0, acceptedBytes <= WatchEpisodeSendLimits.maxEpisodeBytes else {
        throw WatchDownloadStoreError.fileSizeMismatch
      }
      measured = try vault.measuredTemporaryFile(
        temporaryFileURL, expectedBytes: acceptedBytes, responseBytes: nil)
    } catch {
      markFailed(selection: selection, revision: revision, reason: .invalidResponse)
      return .discarded(.sizeMismatch)
    }

    // The path was fixed at admission from the offer's MIME, which is also the persisted MIME, so
    // it never has to be re-derived here.
    try vault.install(temporaryFileURL, relativePath: existing.relativePath, measured: measured)

    var entry = existing
    entry.state = .ready
    entry.declineReason = nil
    entry.failureReason = nil
    entry.progress = nil
    entry.committedBytes = measured
    entry.updatedAt = now()
    entriesBySelection[selection] = entry
    // The file is installed whatever the write says, so memory keeps the ready entry.
    try persist(rollingBack: false)
    return .committed(entry)
  }

  /// The installed file for a `ready` entry, validated by the vault (regular file, contained path,
  /// expected byte count).
  public func playableFileURL(for selection: WatchNativeSelection) throws -> URL {
    guard let entry = entriesBySelection[selection] else { throw WatchReceivedEpisodeStoreError.notFound }
    guard entry.state == .ready else { throw WatchReceivedEpisodeStoreError.notPlayable }
    return try vault.completedFile(relativePath: entry.relativePath, expectedBytes: entry.committedBytes)
  }

  /// Deletes the copy and keeps a tombstone at the same revision for the phone to acknowledge. A
  /// tombstone reserves nothing. Returns `false` when there is no entry or it is already removed.
  @discardableResult
  public func remove(_ selection: WatchNativeSelection) throws -> Bool {
    guard var entry = entriesBySelection[selection], entry.state != .removed else { return false }
    try vault.remove(relativePath: entry.relativePath)
    entry.state = .removed
    entry.declineReason = nil
    entry.failureReason = nil
    entry.progress = nil
    entry.committedBytes = nil
    entry.chapters = []
    entry.updatedAt = now()
    entriesBySelection[selection] = entry
    // The file is gone whatever the write says, so memory does not bring the copy back.
    try persist(rollingBack: false)
    return true
  }

  /// Sign-out clears the account's copies. The payload is rewritten empty rather than unlinked so a
  /// subsequent open cannot resurrect a stale manifest.
  public func removeAll() throws {
    vault.removeAllFiles()
    entriesBySelection = [:]
    appliedGeneration = 0
    try persist(rollingBack: false)
  }

  private func persist(rollingBack: Bool = true) throws {
    do {
      try persistence.save(
        Payload(appliedGeneration: appliedGeneration, entries: Self.sorted(entriesBySelection)))
      persistedEntries = entriesBySelection
      persistedGeneration = appliedGeneration
    } catch {
      if rollingBack {
        entriesBySelection = persistedEntries
        appliedGeneration = persistedGeneration
      }
      budget.record(Self.reservation(of: entriesBySelection), for: .receivedEpisodes)
      throw WatchReceivedEpisodeStoreError.storageFailure
    }
    budget.record(Self.reservation(of: entriesBySelection), for: .receivedEpisodes)
  }

  // MARK: Private helpers

  private struct Admission {
    var admitted: [WatchNativeSelection] = []
    var declined: [WatchNativeSelection] = []
  }

  private static func dropAbsentEntries(
    _ offer: WatchEpisodeSendOffer,
    from entries: inout [WatchNativeSelection: WatchReceivedEpisode],
    dropped: inout [WatchNativeSelection], filesToDelete: inout [String]
  ) {
    let offeredSelections = Set(offer.entries.map(\.selection))
    let absentSelections = entries.keys.filter { !offeredSelections.contains($0) }
    for selection in absentSelections {
      let existing = entries[selection]
      if existing?.state == .ready { dropped.append(selection) }
      if let path = existing?.relativePath, path.isEmpty == false { filesToDelete.append(path) }
      entries.removeValue(forKey: selection)
    }
  }

  private static func admitOfferedEntries(
    _ offer: WatchEpisodeSendOffer,
    into entries: inout [WatchNativeSelection: WatchReceivedEpisode],
    dropped: inout [WatchNativeSelection], filesToDelete: inout [String],
    budget: WatchStorageBudget, accountStamp: WatchAccountStamp, now: Date
  ) -> Admission {
    var changes = Admission()
    for offered in offer.entries {
      let selection = offered.selection
      let existing = entries[selection]
      if let existing, existing.revision > offered.revision { continue }
      if let existing, existing.revision == offered.revision {
        // A repeat of the same revision refreshes only the phone's descriptive values. In
        // particular a tombstone stays a tombstone, a decline stays a decline and a failed
        // download stays failed until the phone offers a higher revision; a storage decline is
        // taken back by `readmitDeclined()` once there is room.
        var refreshed = existing
        refreshed.title = offered.title
        refreshed.showTitle = offered.showTitle
        refreshed.duration = offered.duration
        refreshed.phonePosition = offered.position
        refreshed.phoneLastListenedAt = offered.lastListenedAt
        refreshed.updatedAt = now
        entries[selection] = refreshed
        continue
      }

      // A new selection, or a re-send at a higher revision: the old file goes and the position
      // resets to the offer's, because the listener asked for this episode again. A failed
      // download at the old revision reaches here too, so "Try Again" re-queues it.
      if let existing {
        if existing.state == .ready { dropped.append(selection) }
        if existing.relativePath.isEmpty == false { filesToDelete.append(existing.relativePath) }
        entries.removeValue(forKey: selection)
      }

      let relativePath = Self.destinationRelativePath(
        accountStamp: accountStamp, selection: selection, revision: offered.revision,
        mimeType: offered.mimeType)
      let reservation = WatchEnclosureAdmission.reservationBytes(declaredBytes: offered.declaredBytes)
      let prospective = Self.reservation(of: entries) + reservation
      let fits = budget.claim(prospective, for: .receivedEpisodes)
      if fits == false {
        // The claim left the ledger at the previous total, which may still include the file just
        // replaced. Mirror the entries this apply will actually persist.
        budget.record(Self.reservation(of: entries), for: .receivedEpisodes)
        changes.declined.append(selection)
      } else {
        changes.admitted.append(selection)
      }
      entries[selection] = WatchReceivedEpisode(
        selection: selection, revision: offered.revision, state: fits ? .receiving : .declined,
        declineReason: fits ? nil : .storageFull, title: offered.title, showTitle: offered.showTitle,
        duration: offered.duration, enclosureURL: offered.enclosureURL,
        declaredBytes: offered.declaredBytes, mimeType: offered.mimeType,
        chapters: offered.chapters, phonePosition: offered.position,
        phoneLastListenedAt: offered.lastListenedAt, committedBytes: nil, relativePath: relativePath,
        offeredAt: offer.sentAt, updatedAt: now)
    }
    return changes
  }

  private struct OpenedStore {
    var entries: [WatchNativeSelection: WatchReceivedEpisode]
    var generation: UInt64
  }

  /// Reads the payload, drops the rows it cannot express, and rewrites what it had to discard. A
  /// rewrite that fails on the file system rethrows the underlying error; any other failure is a
  /// storage failure.
  private static func open(
    persistence: WatchAccountFencedJSONStore<Payload>, accountStamp: WatchAccountStamp
  ) throws -> OpenedStore {
    var loaded: Payload?
    var needsRewrite = false
    do {
      loaded = try persistence.load()
    } catch WatchFencedStoreError.corrupt {
      needsRewrite = true
    } catch WatchFencedStoreError.versionMismatch {
      needsRewrite = true
    } catch WatchFencedStoreError.foreignAccount {
      // The directory is keyed by the account hash; a foreign stamp here means the identity changed
      // under the same directory. Treat it as empty rather than refusing to start: the copies are
      // re-sendable, and the orphan sweep below removes the previous account's files.
      needsRewrite = true
    } catch {
      throw WatchReceivedEpisodeStoreError.storageFailure
    }

    var restored: [WatchNativeSelection: WatchReceivedEpisode] = [:]
    if let decoded = loaded {
      // One invalid or duplicated row must not make the whole store unreadable on every launch.
      if decoded.droppedEntryCount > 0 { needsRewrite = true }
      for entry in decoded.entries {
        guard restored[entry.selection] == nil, valid(entry, accountStamp: accountStamp) else {
          needsRewrite = true
          continue
        }
        restored[entry.selection] = entry
      }
    }
    let generation = loaded?.appliedGeneration ?? 0

    if needsRewrite || loaded == nil {
      do {
        try persistence.save(Payload(appliedGeneration: generation, entries: sorted(restored)))
      } catch WatchFencedStoreError.io(let error) {
        throw error
      } catch {
        throw WatchReceivedEpisodeStoreError.storageFailure
      }
    }
    return OpenedStore(entries: restored, generation: generation)
  }

  /// A digest of the account, selection and revision plus the MIME-derived extension. Only the
  /// digest becomes a path component, exactly like `WatchDownloadStore.destinationRelativePath`.
  static func destinationRelativePath(
    accountStamp: WatchAccountStamp, selection: WatchNativeSelection, revision: UInt64,
    mimeType: String
  ) -> String {
    let material =
      "rss\u{1F}\(accountStamp.accountIdentityHash)\u{1F}\(accountStamp.serverIdentityHash)"
      + "\u{1F}\(selection.feedID)\u{1F}\(selection.episodeID)\u{1F}\(revision)"
    let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(digest).\(WatchDownloadStore.fileExtension(for: mimeType))"
  }

  private static func sorted(
    _ entries: [WatchNativeSelection: WatchReceivedEpisode]
  ) -> [WatchReceivedEpisode] {
    entries.values.sorted {
      if $0.offeredAt != $1.offeredAt { return $0.offeredAt > $1.offeredAt }
      if $0.selection.feedID != $1.selection.feedID {
        return $0.selection.feedID < $1.selection.feedID
      }
      return $0.selection.episodeID < $1.selection.episodeID
    }
  }

  private static func reservation(
    of entries: [WatchNativeSelection: WatchReceivedEpisode]
  ) -> Int64 {
    entries.values.reduce(Int64(0)) { total, entry in
      switch entry.state {
      case .receiving, .downloading, .waitingForNetwork: return total + entry.reservedBytes
      case .ready: return total + (entry.committedBytes ?? 0)
      case .failed, .declined, .removed: return total
      }
    }
  }

  private static func removeOrphanedFiles(
    vault: WatchDownloadFileVault, rootURL: URL, keeping: Set<String>
  ) {
    let filesURL = rootURL.appendingPathComponent("files", isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: filesURL.path) else { return }
    for name in names where !keeping.contains(name) {
      try? vault.remove(relativePath: name)
    }
  }

  private static func discardFile(_ url: URL) {
    let fileManager = FileManager.default
    guard (try? fileManager.attributesOfItem(atPath: url.path)) != nil else { return }
    try? fileManager.removeItem(at: url)
  }

  private static func valid(_ entry: WatchReceivedEpisode, accountStamp: WatchAccountStamp) -> Bool {
    guard (try? entry.selection.validate()) != nil,
      entry.revision > 0,
      validMetadata(entry.title), validMetadata(entry.showTitle), validMIMEType(entry.mimeType),
      entry.phonePosition.isFinite, entry.phonePosition >= 0,
      entry.phonePosition <= WatchHandoffLimits.maxPositionSeconds,
      entry.phoneLastListenedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
      entry.offeredAt.timeIntervalSinceReferenceDate.isFinite,
      entry.updatedAt.timeIntervalSinceReferenceDate.isFinite,
      entry.duration.map({ $0.isFinite && $0 > 0 && $0 <= WatchHandoffLimits.maxPositionSeconds }) ?? true,
      entry.chapters.count <= WatchEpisodeSendLimits.maxChapters,
      entry.reservedBytes == WatchEnclosureAdmission.reservationBytes(declaredBytes: entry.declaredBytes),
      entry.relativePath
        == destinationRelativePath(
          accountStamp: accountStamp, selection: entry.selection, revision: entry.revision,
          mimeType: entry.mimeType)
    else { return false }

    if let declaredBytes = entry.declaredBytes {
      guard declaredBytes > 0, declaredBytes <= WatchEpisodeSendLimits.maxEpisodeBytes else {
        return false
      }
    }
    if let enclosureURL = entry.enclosureURL, !WatchEnclosureURL.isValid(enclosureURL) {
      return false
    }
    var previousStart = -Double.infinity
    for chapter in entry.chapters {
      guard (try? chapter.validate()) != nil, chapter.start >= previousStart else { return false }
      previousStart = chapter.start
    }

    switch entry.state {
    case .declined:
      return entry.declineReason != nil && entry.committedBytes == nil
        && entry.progress == nil && entry.failureReason == nil
    case .ready:
      return entry.declineReason == nil && entry.failureReason == nil && entry.progress == nil
        && entry.committedBytes.map({ $0 > 0 && $0 <= WatchEpisodeSendLimits.maxEpisodeBytes }) == true
    case .downloading:
      return entry.declineReason == nil && entry.committedBytes == nil && entry.failureReason == nil
        && entry.enclosureURL != nil
        && (entry.progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true)
    case .failed:
      return entry.failureReason != nil && entry.declineReason == nil
        && entry.committedBytes == nil && entry.progress == nil
    case .receiving, .waitingForNetwork:
      return entry.declineReason == nil && entry.committedBytes == nil && entry.progress == nil
        && entry.failureReason == nil && entry.enclosureURL != nil
    case .removed:
      return entry.declineReason == nil && entry.committedBytes == nil && entry.progress == nil
        && entry.failureReason == nil
    }
  }

  private static func validMetadata(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes
      && !value.contains("://") && !value.hasPrefix("/") && !value.lowercased().hasPrefix("file:")
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func validMIMEType(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= WatchEpisodeSendLimits.maxMimeTypeBytes
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
