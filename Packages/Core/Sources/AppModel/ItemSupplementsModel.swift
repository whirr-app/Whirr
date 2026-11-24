import Foundation
import Observation
import Persistence
import SyncEngine

/// What a screen needs to offer an audiobook's companion PDFs: the stored set, joined with each
/// file's download state, from the local database only. Opening a PDF that is not on this device
/// plans its download; nothing here makes the item an ebook or touches its own download state.
@MainActor
@Observable
public final class ItemSupplementsModel {
  public private(set) var supplements: [ItemSupplement] = []
  /// The last request's failure as renderable copy, `nil` once a request succeeds.
  public private(set) var actionErrorMessage: String?

  public let itemID: String
  private let reading: any ItemSupplementReading
  private let downloadIntents: any DownloadIntents

  @ObservationIgnored private var task: Task<Void, Never>?

  public init(
    itemID: String, reading: any ItemSupplementReading, downloadIntents: any DownloadIntents
  ) {
    self.itemID = itemID
    self.reading = reading
    self.downloadIntents = downloadIntents
    let stream = reading.observeSupplements(itemId: itemID)
    task = Task { [weak self] in
      for await supplements in stream {
        guard let self else { return }
        self.supplements = supplements
      }
    }
  }

  deinit {
    task?.cancel()
  }

  public func supplement(ino: String) -> ItemSupplement? {
    supplements.first { $0.serverFileIno == ino }
  }

  /// Makes the PDF available: a no-op once it is local or moving, otherwise a single-file request
  /// that the ordinary download policy (including the cellular hold) then carries out.
  public func prepare(_ supplement: ItemSupplement) async {
    switch supplement.fileState {
    case .ready, .downloading, .waitingForWiFi, .deleting:
      return
    case .notDownloaded, .paused, .failed:
      break
    }
    do {
      try await downloadIntents.requestSupplementDownload(
        itemID: itemID, fileIno: supplement.serverFileIno)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = ItemSupplementPresentation.downloadFailedMessage
    }
  }

  /// Device-local page memory. Never reaches the server.
  public func setLastViewedPage(_ page: Int, for supplement: ItemSupplement) async {
    await reading.setLastViewedPage(
      itemId: itemID, serverFileIno: supplement.serverFileIno, page: page)
  }
}

/// A reader that has no supplements: previews, harnesses, and compositions before sign-in.
public struct NoOpItemSupplementReading: ItemSupplementReading {
  public init() {}
  public func observeSupplements(itemId: String) -> AsyncStream<[ItemSupplement]> {
    AsyncStream { $0.finish() }
  }
  public func setLastViewedPage(itemId: String, serverFileIno: String, page: Int) async {}
}

/// The copy and state choices every supplement surface shares, kept out of the views so the detail
/// row, the player menu and the viewer cannot drift.
public enum ItemSupplementPresentation {
  public static let genericTitle = "Companion PDF"
  public static let downloadFailedMessage = "Couldn't download this PDF."

  /// Filenames that describe the artefact rather than its content read as the generic title.
  private static let genericStems: Set<String> = [
    "supplement", "supplements", "supplemental", "bonus", "booklet", "companion", "pdf",
    "extras", "extra", "accompanying material", "accompanying", "insert", "attachment",
  ]

  /// The filename without its extension, unless it says nothing about the content.
  public static func title(for supplement: ItemSupplement) -> String {
    guard let filename = supplement.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
      filename.isEmpty == false
    else { return genericTitle }
    let stem = (filename as NSString).deletingPathExtension
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = stem.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hasLetters = normalized.contains { $0.isLetter }
    guard hasLetters, genericStems.contains(normalized) == false else { return genericTitle }
    return stem
  }

  /// Only proven unreachability counts: `.unknown` at cold launch is not an outage, and a file
  /// request made then simply waits in the queue like any other.
  public static func isOffline(_ reachability: ServerReachability?) -> Bool {
    if case .unreachable = reachability { return true }
    return false
  }

  /// The detail row's title: the one PDF's own title, or a count.
  public static func rowTitle(for supplements: [ItemSupplement]) -> String {
    switch supplements.count {
    case 0: return ""
    case 1: return title(for: supplements[0])
    default: return "\(supplements.count) PDFs"
    }
  }

  /// The player's ⋯ menu entry.
  public static func menuLabel(count: Int) -> String {
    count > 1 ? "Supplements…" : "View PDF"
  }

  /// What sits at the trailing edge of a supplement row.
  public enum Trailing: Equatable, Sendable {
    case size(String)
    case progress(Double)
    case waitingForWiFi
    case unavailableOffline
    case failed
    case none
  }

  public static func trailing(for supplement: ItemSupplement, isOffline: Bool) -> Trailing {
    switch supplement.fileState {
    case .ready:
      return .none
    case .downloading(let progress):
      return .progress(progress)
    case .waitingForWiFi:
      return .waitingForWiFi
    case .failed where isOffline == false:
      return .failed
    case .notDownloaded, .paused, .deleting, .failed:
      return isOffline ? .unavailableOffline : .size(sizeText(supplement.sizeBytes))
    }
  }

  /// A row of several PDFs summarises them: the first one that needs attention wins.
  public static func trailing(for supplements: [ItemSupplement], isOffline: Bool) -> Trailing {
    guard supplements.count > 1 else {
      return supplements.first.map { trailing(for: $0, isOffline: isOffline) } ?? .none
    }
    let states = supplements.map { trailing(for: $0, isOffline: isOffline) }
    if let progress = states.first(where: { if case .progress = $0 { true } else { false } }) {
      return progress
    }
    if states.contains(.waitingForWiFi) { return .waitingForWiFi }
    if states.allSatisfy({ $0 == .none }) { return .none }
    if states.contains(.unavailableOffline) { return .unavailableOffline }
    let total = supplements.filter { trailing(for: $0, isOffline: isOffline) != .none }
      .reduce(into: Int64(0)) { $0 += $1.sizeBytes }
    return .size(sizeText(total))
  }

  public static func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  /// The viewer's whole-screen state.
  public enum ViewerState: Equatable, Sendable {
    case downloading(progress: Double)
    case waitingForWiFi
    case ready(fileURL: URL)
    case failed
    case unavailableOffline
  }

  public static func viewerState(for supplement: ItemSupplement, isOffline: Bool) -> ViewerState {
    switch supplement.fileState {
    case .ready(let url):
      return .ready(fileURL: url)
    case .downloading(let progress):
      return .downloading(progress: progress)
    case .waitingForWiFi:
      return .waitingForWiFi
    case .failed where isOffline == false:
      return .failed
    case .notDownloaded, .paused, .deleting, .failed:
      return isOffline ? .unavailableOffline : .downloading(progress: 0)
    }
  }
}
