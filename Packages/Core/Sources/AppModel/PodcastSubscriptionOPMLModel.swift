import Foundation
import Observation
import Persistence
import PodcastFeeds

public protocol NativeSubscriptionOPMLExporting: Sendable {
  func exportOPML() async throws -> Data
}

public struct NoOpNativeSubscriptionOPMLExporter: NativeSubscriptionOPMLExporting {
  public init() {}
  public func exportOPML() async throws -> Data {
    try OPML.serializeChecked(OPMLDocument(title: "Whirr Podcasts", entries: []))
  }
}

public struct RSSSubscriptionOPMLExporter: NativeSubscriptionOPMLExporting {
  private let store: RSSFeedStore

  public init(store: RSSFeedStore) { self.store = store }

  public func exportOPML() async throws -> Data {
    let entries = try await store.fetchFeeds().compactMap { feed -> OPMLFeedEntry? in
      guard let url = URL(string: feed.feedURL), FeedEndpoint(url: url) != nil else { return nil }
      return OPMLFeedEntry(title: feed.title, feedURL: url, siteURL: nil)
    }
    return try OPML.serializeChecked(OPMLDocument(title: "Whirr Podcasts", entries: entries))
  }
}

public enum OPMLImportFailure: Sendable, Equatable {
  case invalidDocument
  case noFeeds
}

public struct OPMLImportRow: Sendable, Equatable, Identifiable {
  public enum Status: Sendable, Equatable {
    case pending
    case following
    case followed(feedId: Int64)
    case failed(AddFeedError)
  }

  public let id: Int
  public let title: String
  public let feedURL: URL
  public var isSelected: Bool
  public var status: Status

  public init(
    id: Int, title: String, feedURL: URL, isSelected: Bool = true,
    status: Status = .pending
  ) {
    self.id = id
    self.title = title
    self.feedURL = feedURL
    self.isSelected = isSelected
    self.status = status
  }
}

@MainActor
@Observable
public final class PodcastSubscriptionOPMLModel {
  nonisolated public static let maximumImportBytes = OPML.maximumDocumentBytes
  public static let exportFilename = "Whirr Podcast Subscriptions.opml"

  public private(set) var rows: [OPMLImportRow] = []
  public private(set) var importFailure: OPMLImportFailure?
  public private(set) var isFollowing = false
  public private(set) var exportURL: URL?
  public private(set) var exportError = false

  public private(set) var followCompletedCount = 0
  public private(set) var followTotalCount = 0

  public var selectedCount: Int {
    rows.count { $0.isSelected && $0.status == .pending }
  }

  /// What the sheet's single pinned commit control is for right now. An import whose rows have
  /// all reached a terminal status has nothing left to follow, so the control becomes the way
  /// out rather than a permanently disabled "Follow".
  public var commitState: PodcastImportCommitState {
    if isFollowing {
      return .following(completed: followCompletedCount, total: followTotalCount)
    }
    if rows.isEmpty == false, rows.contains(where: { $0.status == .pending }) == false {
      return .done
    }
    return .follow(count: selectedCount)
  }

  private let previews: any FeedPreviewProviding
  private let following: any NativeFeedFollowing
  private let exporter: any NativeSubscriptionOPMLExporting
  private let now: @Sendable () -> Date
  private let parsing: @Sendable (Data) async throws -> OPMLDocument
  @ObservationIgnored private var importGeneration: UInt64 = 0
  @ObservationIgnored private var exportGeneration: UInt64 = 0
  @ObservationIgnored private var managedExportURLs: Set<URL> = []
  private var nextRowID = 0

  public convenience init() {
    self.init(previews: FeedPreviewClient(), following: NoOpNativeFeedFollowing())
  }

  public convenience init(
    previews: any FeedPreviewProviding,
    following: any NativeFeedFollowing,
    exporter: any NativeSubscriptionOPMLExporting = NoOpNativeSubscriptionOPMLExporter(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.init(
      previews: previews,
      following: following,
      exporter: exporter,
      now: now,
      parsing: { data in
        try await Task.detached { try OPML.parse(data) }.value
      })
  }

  init(
    previews: any FeedPreviewProviding,
    following: any NativeFeedFollowing,
    exporter: any NativeSubscriptionOPMLExporting = NoOpNativeSubscriptionOPMLExporter(),
    now: @escaping @Sendable () -> Date = Date.init,
    parsing: @escaping @Sendable (Data) async throws -> OPMLDocument
  ) {
    self.previews = previews
    self.following = following
    self.exporter = exporter
    self.now = now
    self.parsing = parsing
  }

  public func loadImport(data: Data) async {
    importGeneration &+= 1
    let generation = importGeneration
    importFailure = nil
    rows = []
    do {
      let document = try await parsing(data)
      guard generation == importGeneration, Task.isCancelled == false else { return }
      var seen = Set<URL>()
      rows = document.entries.compactMap { entry in
        guard seen.insert(entry.feedURL).inserted else { return nil }
        let rowID = nextRowID
        nextRowID += 1
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        return OPMLImportRow(
          id: rowID,
          title: displayTitle ?? entry.feedURL.host ?? entry.feedURL.absoluteString,
          feedURL: entry.feedURL)
      }
      if rows.isEmpty { importFailure = .noFeeds }
    } catch {
      guard generation == importGeneration, Task.isCancelled == false else { return }
      importFailure = .invalidDocument
    }
  }

  public func setSelected(_ selected: Bool, rowID: Int) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }), rows[index].status == .pending else {
      return
    }
    rows[index].isSelected = selected
  }

  /// Each selected feed commits independently. One invalid or duplicate feed remains legible on
  /// its own row and cannot roll back successful follows from the same import.
  public func followSelected() async {
    let selected = rows.filter { $0.isSelected && $0.status == .pending }
    guard selected.isEmpty == false, isFollowing == false else { return }
    isFollowing = true
    followCompletedCount = 0
    followTotalCount = selected.count

    let subscribedAt = now()
    for row in selected {
      guard Task.isCancelled == false else { break }
      guard rows.contains(where: { $0.id == row.id }) else { continue }
      updateStatus(.following, for: row.id)
      do {
        let preview = try await previews.preview(for: row.feedURL)
        let feedID = try await following.follow(preview, subscribedAt: subscribedAt)
        updateStatus(.followed(feedId: feedID), for: row.id)
      } catch let error as FeedPreviewError {
        updateStatus(.failed(AddFeedError(feedPreviewError: error)), for: row.id)
      } catch let error as FollowFeedError {
        if case .alreadyFollowing = error {
          updateStatus(.failed(.alreadyFollowing), for: row.id)
        } else {
          updateStatus(.failed(.couldNotFollow), for: row.id)
        }
      } catch is CancellationError {
        updateStatus(.pending, for: row.id)
        break
      } catch {
        updateStatus(.failed(.couldNotFollow), for: row.id)
      }
      followCompletedCount += 1
    }
    isFollowing = false
  }

  public func prepareExport(in directory: URL = FileManager.default.temporaryDirectory) async {
    exportGeneration &+= 1
    let generation = exportGeneration
    exportError = false
    var candidateURL: URL?
    do {
      let data = try await exporter.exportOPML()
      try Task.checkCancellation()
      guard generation == exportGeneration else { return }
      let base = (Self.exportFilename as NSString).deletingPathExtension
      let url = directory.appendingPathComponent(
        "\(base)-\(UUID().uuidString).opml", isDirectory: false)
      candidateURL = url
      managedExportURLs.insert(url)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      let previousURL = exportURL
      exportURL = url
      if let previousURL { removeManagedExport(at: previousURL) }
    } catch {
      if let candidateURL { removeManagedExport(at: candidateURL) }
      guard generation == exportGeneration else { return }
      if let exportURL { removeManagedExport(at: exportURL) }
      exportURL = nil
      exportError = true
    }
  }

  public func resetImport() {
    importGeneration &+= 1
    rows = []
    importFailure = nil
    isFollowing = false
    followCompletedCount = 0
    followTotalCount = 0
  }

  deinit {
    for url in managedExportURLs {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func updateStatus(_ status: OPMLImportRow.Status, for rowID: Int) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    rows[index].status = status
  }

  private func removeManagedExport(at url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
      managedExportURLs.remove(url)
    } catch CocoaError.fileNoSuchFile {
      managedExportURLs.remove(url)
    } catch {
      // Keep ownership so the model lifetime boundary can retry a transient unlink failure.
    }
  }
}
