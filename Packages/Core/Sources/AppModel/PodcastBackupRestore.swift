import Foundation
import Observation
import Persistence
import SyncEngine

/// A backup file read and checked, ready to preview or restore.
public struct PodcastBackupDocument: Sendable, Equatable {
  public let exportedAt: Date
  public let showCount: Int
  let contents: NativePodcastBackupContents
  /// The file's smart lists, restored separately from the podcast state.
  let smartLists: PodcastSmartListsSnapshot?

  init(
    exportedAt: Date, showCount: Int, contents: NativePodcastBackupContents,
    smartLists: PodcastSmartListsSnapshot? = nil
  ) {
    self.exportedAt = exportedAt
    self.showCount = showCount
    self.contents = contents
    self.smartLists = smartLists
  }
}

public enum PodcastBackupReadFailure: Error, Sendable, Equatable {
  /// Not a Whirr podcast backup, damaged, or outside the file's limits.
  case unreadable
  /// Written by a newer Whirr than this one.
  case newerVersion
}

public protocol PodcastBackupRestoring: Sendable {
  func read(_ data: Data) async throws -> PodcastBackupDocument
  func preview(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome
  func restore(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome
  /// How many smart lists `restoreSmartLists` would add now.
  func previewSmartLists(_ document: PodcastBackupDocument) async throws -> Int
  /// Run after `restore` succeeds. Nil when the document has no smart lists.
  func restoreSmartLists(_ document: PodcastBackupDocument) async throws
    -> PodcastSmartListsSnapshotCodec.RestoreOutcome?
}

extension PodcastBackupRestoring {
  public func previewSmartLists(_ document: PodcastBackupDocument) async throws -> Int { 0 }

  public func restoreSmartLists(_ document: PodcastBackupDocument) async throws
    -> PodcastSmartListsSnapshotCodec.RestoreOutcome?
  { nil }
}

public struct NativePodcastBackupRestoreService: PodcastBackupRestoring {
  private let restorer: NativePodcastBackupRestorer
  private let database: AppDatabase
  private let now: @Sendable () -> Date

  public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
    self.database = database
    self.restorer = NativePodcastBackupRestorer(database: database)
    self.now = now
  }

  /// Nonisolated, so decoding a file of up to 32 MiB runs off the main actor.
  public func read(_ data: Data) async throws -> PodcastBackupDocument {
    let snapshot: PodcastStateSnapshot
    do {
      snapshot = try PodcastStateSnapshotCodec.decodeWrapped(data)
    } catch PodcastStateSnapshotCodecError.unsupportedVersion(let version) where version > 1 {
      throw PodcastBackupReadFailure.newerVersion
    } catch {
      throw PodcastBackupReadFailure.unreadable
    }
    var contents = PodcastBackupSnapshotMapping.contents(
      from: snapshot, learnedAdPrintFormat: PodcastBackupLearnedAds.printFormat)
    contents.learnedAds = PodcastBackupLearnedAds.current(contents.learnedAds, asOf: now())
    return PodcastBackupDocument(
      exportedAt: snapshot.exportedAt, showCount: contents.feeds.count, contents: contents,
      smartLists: snapshot.smartLists)
  }

  public func preview(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome {
    try await restorer.preview(document.contents)
  }

  public func restore(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome {
    try await restorer.restore(document.contents)
  }

  public func previewSmartLists(_ document: PodcastBackupDocument) async throws -> Int {
    guard let section = document.smartLists else { return 0 }
    var names = Set(try await SmartListStore(database: database).lists().map { $0.name.lowercased() })
    var room = PodcastSmartListsSnapshotCodec.maxLists - names.count
    var added = 0
    for list in section.lists where room > 0 {
      guard let name = SmartListRules.normalizedName(list.name), (try? list.rules.validate()) != nil,
        names.insert(name.lowercased()).inserted
      else { continue }
      room -= 1
      added += 1
    }
    return added
  }

  public func restoreSmartLists(_ document: PodcastBackupDocument) async throws
    -> PodcastSmartListsSnapshotCodec.RestoreOutcome?
  {
    guard let section = document.smartLists else { return nil }
    return try await PodcastSmartListsSnapshotCodec.restore(section, into: database)
  }
}

/// Restore as the Backups screen drives it: read → preview → confirm → restore.
@MainActor @Observable
public final class PodcastBackupRestoreModel {
  public enum Failure: Equatable, Sendable {
    case unreadable
    case newerVersion
    /// iCloud Sync is on and could not finish, so restoring now might overwrite newer progress
    /// from another device that has not arrived yet.
    case syncNotReady
    case couldNotRestore
  }

  public enum Phase: Equatable, Sendable {
    case idle
    case reading
    case preview(PodcastBackupDocument, NativePodcastRestoreOutcome)
    case restoring
    case finished(NativePodcastRestoreOutcome)
    case failed(Failure)
  }

  public private(set) var phase: Phase = .idle
  /// What the last restore did with smart lists. Nil when the file had none, or smart lists could
  /// not be restored; the podcast state was restored either way.
  /// Smart lists the previewed backup would add. They count as a change, so a file that differs
  /// only in lists can still be merged.
  public private(set) var smartListsPending = 0
  public private(set) var smartListOutcome: PodcastSmartListsSnapshotCodec.RestoreOutcome?
  /// The main restore succeeded but the smart-list section did not.
  public private(set) var smartListsFailed = false

  private let service: any PodcastBackupRestoring
  private let sync: (any PodcastCloudSyncControlling)?
  private let refreshFeeds: @Sendable ([Int64]) async -> Void
  private let learnedAdsRestored: @Sendable () async -> Void
  private var generation = GenerationFence()

  /// `learnedAdsRestored` runs after a restore that added or changed learned ads, for the ad-skip
  /// coordinator, which holds the store's audio prints in memory and owes a recompute.
  public init(
    service: any PodcastBackupRestoring, sync: (any PodcastCloudSyncControlling)?,
    learnedAdsRestored: @escaping @Sendable () async -> Void = {},
    refreshFeeds: @escaping @Sendable ([Int64]) async -> Void
  ) {
    self.service = service
    self.sync = sync
    self.learnedAdsRestored = learnedAdsRestored
    self.refreshFeeds = refreshFeeds
  }

  public func read(_ data: Data) async {
    let current = generation.advance()
    phase = .reading
    do {
      let document = try await service.read(data)
      let outcome = try await service.preview(document)
      let pending = (try? await service.previewSmartLists(document)) ?? 0
      guard generation.isCurrent(current) else { return }
      smartListsPending = pending
      phase = .preview(document, outcome)
    } catch PodcastBackupReadFailure.newerVersion {
      guard generation.isCurrent(current) else { return }
      phase = .failed(.newerVersion)
    } catch is PodcastBackupReadFailure {
      guard generation.isCurrent(current) else { return }
      phase = .failed(.unreadable)
    } catch {
      guard generation.isCurrent(current) else { return }
      phase = .failed(.couldNotRestore)
    }
  }

  /// With sync on, a sync runs first and must reach up to date: restore then writes against
  /// everything the other devices have sent.
  public func confirm() async {
    guard case .preview(let document, _) = phase else { return }
    let current = generation.advance()
    phase = .restoring
    smartListOutcome = nil
    smartListsFailed = false
    if let sync, await sync.status() != .off {
      do { try await sync.syncNow() } catch {}
      guard await sync.status() == .upToDate else {
        if generation.isCurrent(current) { phase = .failed(.syncNotReady) }
        return
      }
    }
    do {
      let outcome = try await service.restore(document)
      let smartLists: Result<PodcastSmartListsSnapshotCodec.RestoreOutcome?, any Error>
      do { smartLists = .success(try await service.restoreSmartLists(document)) } catch {
        smartLists = .failure(error)
      }
      guard generation.isCurrent(current) else { return }
      switch smartLists {
      case .success(let value): smartListOutcome = value
      case .failure: smartListsFailed = true
      }
      phase = .finished(outcome)
      if outcome.learnedAdsAdded > 0 || outcome.learnedAdsChanged > 0 { await learnedAdsRestored() }
      if outcome.addedFeedIDs.isEmpty == false {
        let feeds = outcome.addedFeedIDs
        let refresh = refreshFeeds
        Task { await refresh(feeds) }
      }
    } catch {
      guard generation.isCurrent(current) else { return }
      phase = .failed(.couldNotRestore)
    }
  }

  public func reset() {
    generation.advance()
    phase = .idle
  }
}
