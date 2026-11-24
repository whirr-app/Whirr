import AdSkip
import Foundation
import Observation
import Persistence
import SyncEngine

/// A written backup and what it holds, for the confirmation the user sees before sharing it.
public struct PodcastBackupExport: Sendable, Equatable {
  public let data: Data
  public let showCount: Int
  public let episodeCount: Int
  /// Shows and episodes the file could not carry; see `PodcastBackupSnapshotMapping.Result`.
  public let skippedShows: Int
  public let skippedEpisodes: Int
  /// Learned ads and undone skips in the file.
  public let learnedAdCount: Int
  /// Smart lists in the file.
  public let smartListCount: Int

  public init(
    data: Data, showCount: Int, episodeCount: Int, skippedShows: Int = 0, skippedEpisodes: Int = 0,
    learnedAdCount: Int = 0, smartListCount: Int = 0
  ) {
    self.data = data
    self.showCount = showCount
    self.episodeCount = episodeCount
    self.skippedShows = skippedShows
    self.skippedEpisodes = skippedEpisodes
    self.learnedAdCount = learnedAdCount
    self.smartListCount = smartListCount
  }

  /// The file carries no show, no episode and no learned ad, as after a reinstall or a lost
  /// database. Writing it over a real backup would destroy what the backup is for. Learned ads
  /// count: a listener with only server podcasts has them and no shows here. So do smart lists.
  public var isEmpty: Bool { showCount == 0 && episodeCount == 0 && learnedAdCount == 0 && smartListCount == 0 }
}

/// How a backup carries learned ads, as far as this layer decides it.
public enum PodcastBackupLearnedAds {
  /// Names the audio print algorithm by the parameters that change its output. A backup whose
  /// value differs restores its ads without their prints.
  public static let printFormat = "fp-\(AudioPrint.sampleRate)-\(AudioPrint.frameLength)-\(AudioPrint.hopLength)"

  /// Ads the store would expire on its next pass are not worth carrying either way. The store owns
  /// that rule: a confirmed ad never expires, so it travels however old it is.
  static func current(
    _ ads: [NativePodcastBackupContents.LearnedAd], asOf date: Date
  ) -> [NativePodcastBackupContents.LearnedAd] {
    ads.filter {
      SignatureStore.isExpired(confirmed: $0.confirmed, lastSeen: $0.lastSeen, asOf: date) == false
    }
  }
}

public protocol PodcastBackupExporting: Sendable {
  func exportBackup(at date: Date) async throws -> PodcastBackupExport
}

/// Reads the native podcast state and encodes it as a `.whirrpodcasts.json` document. Needs no
/// CloudKit consent, account or network.
public struct NativePodcastBackupExporter: PodcastBackupExporting {
  private let reader: NativePodcastBackupReader
  private let database: AppDatabase
  private let appBuild: String?

  public init(database: AppDatabase, appBuild: String? = nil) {
    self.database = database
    self.reader = NativePodcastBackupReader(database: database)
    self.appBuild = appBuild
  }

  public func exportBackup(at date: Date) async throws -> PodcastBackupExport {
    var contents = try await reader.contents()
    contents.learnedAds = PodcastBackupLearnedAds.current(contents.learnedAds, asOf: date)
    let smartLists = try await PodcastSmartListsSnapshotCodec.export(from: database).snapshot
    do {
      return try export(contents, smartLists: smartLists, at: date)
    } catch PodcastStateSnapshotCodecError.tooLarge where contents.learnedAds.isEmpty == false {
      // The section's budget is an estimate. Podcast state is never lost to a wrong one.
      contents.learnedAds = []
      return try export(contents, smartLists: smartLists, at: date)
    }
  }

  private func export(
    _ contents: NativePodcastBackupContents, smartLists: PodcastSmartListsSnapshot?, at date: Date
  ) throws -> PodcastBackupExport {
    let result = try PodcastBackupSnapshotMapping.snapshot(
      from: contents, exportedAt: date, appBuild: appBuild, learnedAdPrintFormat: PodcastBackupLearnedAds.printFormat,
      smartLists: smartLists)
    return PodcastBackupExport(
      data: try PodcastStateSnapshotCodec.encodeWrapped(result.snapshot),
      showCount: result.snapshot.subscriptions.count, episodeCount: result.snapshot.episodes.count,
      skippedShows: result.skippedFeeds, skippedEpisodes: result.skippedEpisodes,
      learnedAdCount: result.snapshot.learnedAds?.ads.count ?? 0,
      smartListCount: result.snapshot.smartLists?.lists.count ?? 0)
  }
}

@MainActor @Observable
public final class PodcastBackupModel {
  public private(set) var exportURL: URL?
  public private(set) var lastExport: PodcastBackupExport?
  public private(set) var exportError = false
  public private(set) var isExporting = false

  private let exporter: any PodcastBackupExporting
  private let now: @Sendable () -> Date
  private let calendar: Calendar
  private var exportGeneration = 0
  /// Each export lives in its own directory so the shared file keeps a readable name.
  @ObservationIgnored private var managedDirectories: Set<URL> = []

  public init(
    exporter: any PodcastBackupExporting, now: @escaping @Sendable () -> Date = Date.init,
    calendar: Calendar = .current
  ) {
    self.exporter = exporter
    self.now = now
    self.calendar = calendar
  }

  public func filename(for date: Date) -> String {
    PodcastAutoBackupPolicy.filename(for: date, calendar: calendar)
  }

  public func prepareExport(in directory: URL = FileManager.default.temporaryDirectory) async {
    exportGeneration &+= 1
    let generation = exportGeneration
    exportError = false
    isExporting = true
    defer { if generation == exportGeneration { isExporting = false } }
    var candidate: URL?
    do {
      let date = now()
      let export = try await exporter.exportBackup(at: date)
      try Task.checkCancellation()
      guard generation == exportGeneration else { return }
      let folder = directory.appendingPathComponent("WhirrBackup-\(UUID().uuidString)", isDirectory: true)
      candidate = folder
      managedDirectories.insert(folder)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(filename(for: date), isDirectory: false)
      try export.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      let previous = exportURL
      exportURL = url
      lastExport = export
      if let previous { removeManaged(previous.deletingLastPathComponent()) }
    } catch {
      if let candidate { removeManaged(candidate) }
      guard generation == exportGeneration else { return }
      if let exportURL { removeManaged(exportURL.deletingLastPathComponent()) }
      exportURL = nil
      lastExport = nil
      exportError = true
    }
  }

  deinit {
    for directory in managedDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func removeManaged(_ directory: URL) {
    do {
      try FileManager.default.removeItem(at: directory)
      managedDirectories.remove(directory)
    } catch CocoaError.fileNoSuchFile {
      managedDirectories.remove(directory)
    } catch {
      // Keep ownership so the model lifetime boundary can retry a transient unlink failure.
    }
  }
}
