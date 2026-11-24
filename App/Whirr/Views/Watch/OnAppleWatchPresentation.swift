import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence

/// How far a multi-part book has come down to the Watch, from the Watch's latest report.
struct OnAppleWatchParts: Equatable, Sendable {
  let completed: Int
  let total: Int
}

/// What the On Apple Watch screen says about one title, and the one thing the listener can do
/// about it. Pure and deterministic from the stored row, the Watch's latest download report and
/// what its last status report said it can do (ADR 0020 Decision 6, ADR 0021).
enum OnAppleWatchStatus: Equatable, Sendable {
  /// No status report has ever arrived for this account's Watch, so the copy may be waiting on an
  /// app that has never been opened.
  case openWhirrOnWatch
  /// A report arrived from a Watch app too old to download the title itself.
  case updateWhirrOnWatch
  /// The Watch app is signed out, or signed in to another account. Setup is on the
  /// Watch, so the row offers nothing.
  case setUpWatch
  case waitingForWatch
  /// The Watch reported a download in progress. The fraction is what its ring draws, across every
  /// part of a book; the words carry no percentage, because the only fraction known is as old as
  /// the Watch's last report. A book with more than one part names the parts once one is in.
  case downloadingOnWatch(progress: Double?, parts: OnAppleWatchParts? = nil)
  case waitingForWiFiOnWatch
  case onWatch
  case watchStorageFull
  case couldNotDownload
  /// The server no longer has the item or episode.
  case notOnServer
  /// The item has no audio the Watch can play.
  case noAudioToDownload
  case removedOnWatch
  /// The Watch app is not installed, or no Watch is paired: the copy's files went with it. Overrides
  /// every stored state except a removal the listener made; those rows keep their own status.
  case watchAppNotInstalled

  var text: String {
    switch self {
    case .openWhirrOnWatch: "Open Whirr on your Watch"
    case .updateWhirrOnWatch: "Update Whirr on your Watch"
    case .setUpWatch: OnAppleWatchPresentation.setUpWatchTitle
    case .waitingForWatch: "Waiting for your Watch"
    case .downloadingOnWatch(_, let parts):
      if let parts, parts.total > 1, parts.completed > 0 {
        "Downloading on Watch · \(parts.completed) of \(parts.total) parts"
      } else {
        "Downloading on Watch"
      }
    case .waitingForWiFiOnWatch: "Waiting for Wi-Fi on Watch"
    case .onWatch: "On Watch"
    case .watchStorageFull: "Watch storage full"
    case .couldNotDownload: "Couldn’t download"
    case .notOnServer: "Not on the server"
    case .noAudioToDownload: "No audio to download"
    case .removedOnWatch: "Removed on Watch"
    case .watchAppNotInstalled: "Whirr isn’t on your Watch"
    }
  }

  /// The fraction the trailing download ring draws, clamped to `0...1`, or nil while the Watch has
  /// not measured one (the view draws an indeterminate spinner then). Nil for every other status.
  var downloadProgressFraction: Double? {
    guard case .downloadingOnWatch(let progress, _) = self,
      let progress, progress.isFinite
    else { return nil }
    return min(max(progress, 0), 1)
  }

  /// Whether the row's download control is a ring or a spinner at all.
  var isDownloading: Bool {
    if case .downloadingOnWatch = self { return true }
    return false
  }

  /// The ring's spoken value, a whole percentage, or nil while no fraction is known.
  var downloadPercentText: String? {
    OnAppleWatchPresentation.percent(downloadProgressFraction).map { "\($0)%" }
  }

  /// The row's recovery action, or nil when it needs none. A failed download is retried, and a copy
  /// the Watch removed is sent again; both go through the desired set's `send`, and a request bumps
  /// the revision. A title the server no longer has, or that has no audio, would fail again.
  var action: OnAppleWatchAction? {
    switch self {
    case .couldNotDownload: .tryAgain
    case .removedOnWatch: .sendAgain
    case .openWhirrOnWatch, .updateWhirrOnWatch, .setUpWatch, .waitingForWatch, .downloadingOnWatch,
      .waitingForWiFiOnWatch, .onWatch, .watchStorageFull, .notOnServer, .noAudioToDownload,
      .watchAppNotInstalled:
      nil
    }
  }
}

enum OnAppleWatchAction: Equatable, Sendable {
  case tryAgain
  case sendAgain

  var title: String {
    switch self {
    case .tryAgain: "Try Again"
    case .sendAgain: "Send Again"
    }
  }

  var systemImage: String {
    switch self {
    case .tryAgain: "arrow.clockwise"
    case .sendAgain: "applewatch"
    }
  }
}

/// One row of the On Apple Watch screen. It stays out of the stores' types: the models resolve the
/// titles, the raw state and the Watch's download report, and this maps them to the copy the screen
/// draws.
struct OnAppleWatchRow: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case book
    case episode
  }

  /// Which desired set the row's actions go to.
  enum Target: Equatable, Sendable {
    case rss(episodeId: Int64)
    case audiobookshelf(ABSWatchCopyKey)
  }

  let id: String
  let kind: Kind
  let target: Target
  let title: String
  /// The show of an episode, or the author of a book; empty when the library names neither.
  let subtitle: String
  /// The identity the shared artwork pipeline keys this row's cover under.
  let artworkItemID: String
  /// The episode's own image, else its show's; an Audiobookshelf title's item cover.
  let artworkSource: ArtworkSource?
  let artworkFallbackSource: ArtworkSource?
  let artworkRevision: ArtworkRevision
  let status: OnAppleWatchStatus
  /// The trailing recovery button, or nil. A download the Watch started itself has none: sending it
  /// from here would make it the phone's.
  let action: OnAppleWatchAction?
  /// Whether the row offers the trailing Remove swipe. A copy the Watch already removed does not.
  let canRemove: Bool
  /// When the phone asked for it; nil for a download the Watch started itself, listed last.
  let requestedAt: Date?
}

/// The screen's two lists, each newest request first with the Watch's own downloads after.
struct OnAppleWatchSections: Equatable, Sendable {
  let audiobooks: [OnAppleWatchRow]
  /// Audiobookshelf and followed-show episodes together, with no source mark, as the Watch's own
  /// shelves draw them.
  let episodes: [OnAppleWatchRow]

  var isEmpty: Bool { audiobooks.isEmpty && episodes.isEmpty }
}

/// How full the Watch's storage budget is, for the bar's tint.
enum OnAppleWatchStorageLevel: Equatable {
  case normal
  case nearlyFull
  case full
}

enum OnAppleWatchPresentation {
  static let title = "On Apple Watch"
  static let emptyTitle = "Nothing on Apple Watch"
  static let emptyMessage =
    "Send a book or an episode to keep it on your Watch. Everything on your Watch appears here."
  static let audiobooksHeader = "Audiobooks"
  static let episodesHeader = "Episodes"
  static let setUpWatchTitle = "Set up Whirr on your Watch"
  static let setUpWatchMessage =
    "Sign in on your Watch with this account to see its audiobooks and episodes here."
  static let removeSwipe = MediaActionCopy.removeFromWatch.title
  static let removeSwipeHint = "Removes it from your Watch."
  /// The trailing swipe, rendered by the app's shared episode vocabulary
  /// (`podcastEpisodeSwipeButtons`): red, `trash` and the short "Remove" every other episode list
  /// draws, so the capsule holds its minimum width. VoiceOver keeps the full phrasing.
  static let removeSwipeButton = PodcastEpisodeSwipeButton(
    id: "removeFromAppleWatch", label: "Remove", accessibilityLabel: removeSwipe,
    hint: removeSwipeHint, systemImage: "trash", role: .destructive, tint: .remove)
  static let storageNotReported = "Not reported yet"
  static let storageSummaryNotReported = "Watch storage not reported yet"
  /// The 2 GB the Watch allows is shared by everything on it, so the screen shows one figure
  /// and never presents one kind of title as a separate allowance.
  static let storageTitle = "Watch Storage"
  /// The setting's key still names episodes (`WatchEpisodeSendPreferences`).
  static let removePlayedTitle = "Remove finished items from Watch"
  /// The phone judges a finish on either device, since it records the Watch's listens too. A
  /// download started on the Watch is the listener's to remove.
  static let removePlayedFooter =
    "Removes a book or episode you sent from your Watch once you finish it, on iPhone or Watch. Downloads started on your Watch stay."

  /// The followed-show rows the screen draws, newest request first, with a copy removed on this
  /// iPhone left out. A copy the Watch removed stays: the listener may want to send it again.
  static func rows(
    _ copies: [WatchEpisodeCopyRow], readiness: WatchAppReadiness
  ) -> [OnAppleWatchRow] {
    copies.compactMap { copy in
      if copy.state == .removed, copy.removedBy == .phone { return nil }
      let status = status(for: copy, readiness: readiness)
      return OnAppleWatchRow(
        id: "rss:\(copy.episodeId)",
        kind: .episode,
        target: .rss(episodeId: copy.episodeId),
        title: copy.title,
        subtitle: copy.showTitle,
        artworkItemID: PodcastSourceIdentity.rss(feedId: copy.feedId)?.itemId
          ?? "rss:\(copy.feedId)",
        artworkSource: copy.artworkSource,
        artworkFallbackSource: copy.artworkFallbackSource,
        artworkRevision: .unversioned,
        status: status,
        action: status.action,
        canRemove: copy.state != .removed,
        requestedAt: copy.requestedAt)
    }
  }

  /// Books in one list and every episode in the other. Phone requests come first, newest first
  /// across both desired sets; the Watch's own downloads follow in the Watch's order.
  static func sections(
    rss: [OnAppleWatchRow], audiobookshelf: [OnAppleWatchRow]
  ) -> OnAppleWatchSections {
    OnAppleWatchSections(
      audiobooks: ordered(audiobookshelf.filter { $0.kind == .book }),
      episodes: ordered(rss + audiobookshelf.filter { $0.kind == .episode }))
  }

  private static func ordered(_ rows: [OnAppleWatchRow]) -> [OnAppleWatchRow] {
    let requested = rows.filter { $0.requestedAt != nil }
    let watchStarted = rows.filter { $0.requestedAt == nil }
    return requested.enumerated().sorted { lhs, rhs in
      let (left, right) = (lhs.element.requestedAt ?? .distantPast, rhs.element.requestedAt ?? .distantPast)
      return left == right ? lhs.offset < rhs.offset : left > right
    }.map(\.element) + watchStarted
  }

  static func status(
    for copy: WatchEpisodeCopyRow, readiness: WatchAppReadiness
  ) -> OnAppleWatchStatus {
    // The Watch's files went with its app, so every live copy says so rather than repeating a
    // report about an install that no longer exists. A row the listener removed stays as it is.
    if readiness == .notInstalled, copy.state != .removed { return .watchAppNotInstalled }
    switch copy.state {
    case .delivered:
      return .onWatch
    case .declined:
      return copy.declineReason == .storageFull ? .watchStorageFull : .couldNotDownload
    case .failed:
      return .couldNotDownload
    case .removed:
      return copy.removedBy == .watch ? .removedOnWatch : .couldNotDownload
    case .wanted, .waitingForWatch:
      return notYetAcknowledged(readiness)
    case .sending:
      return watchDownloadStatus(copy.downloadStatus, readiness: readiness)
    }
  }

  /// The Watch's own report refines the store's coarse in-progress state: it is the only source of
  /// a percentage and of the Wi-Fi hold. A queued entry means the Watch admitted the
  /// offer, so it is acknowledged; a missing entry means no inventory has reported on this
  /// revision yet.
  private static func watchDownloadStatus(
    _ status: WatchEpisodeDownloadStatus?, readiness: WatchAppReadiness
  ) -> OnAppleWatchStatus {
    switch status?.state {
    case .downloading: .downloadingOnWatch(progress: status?.progress)
    case .waitingForNetwork: .waitingForWiFiOnWatch
    case .failed: .couldNotDownload
    case .queued: .waitingForWatch
    case nil: notYetAcknowledged(readiness)
    }
  }

  /// Before the Watch acknowledges a copy, the only fact is what its last status report said about
  /// itself. `canFetch` keeps the original copy; the other two name the one thing the listener can
  /// change on the Watch.
  private static func notYetAcknowledged(_ readiness: WatchAppReadiness) -> OnAppleWatchStatus {
    switch readiness {
    case .unknown: .openWhirrOnWatch
    case .needsUpdate: .updateWhirrOnWatch
    case .canFetch: .waitingForWatch
    case .notInstalled: .watchAppNotInstalled
    }
  }

  /// Whole percent, clamped: the Watch reports a fraction, and a value outside 0...1 is clamped
  /// rather than announced or drawn as a nonsense percentage.
  static func percent(_ fraction: Double?) -> Int? {
    guard let fraction, fraction.isFinite else { return nil }
    return Int((min(max(fraction, 0), 1) * 100).rounded())
  }

  /// Watch storage from the last inventory, read-only. Before one has arrived nothing is known, so
  /// the row says so rather than claiming zero.
  static func storageUsage(usedBytes: Int64?, totalBytes: Int64?) -> String {
    guard let usedBytes, let totalBytes, totalBytes > 0 else { return storageNotReported }
    return "\(bytes(usedBytes)) of \(bytes(totalBytes))"
  }

  /// The screen's storage figure. An inventory taken before the Watch app was deleted or unpaired
  /// describes files that went with it, so the header falls back to the same state it shows before
  /// any inventory has ever arrived.
  static func storageUsage(
    usedBytes: Int64?, totalBytes: Int64?, readiness: WatchAppReadiness
  ) -> String {
    guard readiness != .notInstalled else { return storageNotReported }
    return storageUsage(usedBytes: usedBytes, totalBytes: totalBytes)
  }

  /// The screen's one storage line, above the list.
  static func storageSummary(
    usedBytes: Int64?, totalBytes: Int64?, readiness: WatchAppReadiness
  ) -> String {
    let usage = storageUsage(usedBytes: usedBytes, totalBytes: totalBytes, readiness: readiness)
    guard usage != storageNotReported else { return storageSummaryNotReported }
    return "\(usage) used"
  }

  /// What the budget has left, beside the summary; nil while the figure is unknown.
  static func storageFree(
    usedBytes: Int64?, totalBytes: Int64?, readiness: WatchAppReadiness
  ) -> String? {
    guard readiness != .notInstalled, let usedBytes, let totalBytes, totalBytes > 0 else {
      return nil
    }
    return "\(bytes(totalBytes - usedBytes)) free"
  }

  /// The summary and the free space as one spoken value, since the bar itself is hidden.
  static func storageAccessibilityValue(
    usedBytes: Int64?, totalBytes: Int64?, readiness: WatchAppReadiness
  ) -> String {
    let summary = storageSummary(usedBytes: usedBytes, totalBytes: totalBytes, readiness: readiness)
    guard let free = storageFree(usedBytes: usedBytes, totalBytes: totalBytes, readiness: readiness)
    else { return summary }
    return "\(summary), \(free)"
  }

  /// How the bar is tinted. The Watch declines a copy that would not fit, so a nearly full budget
  /// is worth seeing before a send fails.
  static func storageLevel(fraction: Double) -> OnAppleWatchStorageLevel {
    if fraction >= 1 { return .full }
    if fraction >= 0.9 { return .nearlyFull }
    return .normal
  }

  /// How full the storage bar is drawn, or nil to draw none while the figure is unknown.
  static func storageFraction(
    usedBytes: Int64?, totalBytes: Int64?, readiness: WatchAppReadiness
  ) -> Double? {
    guard readiness != .notInstalled, let usedBytes, let totalBytes, totalBytes > 0 else {
      return nil
    }
    return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
  }

  /// "0 KB" rather than ByteCountFormatter's default "Zero KB" (or "0 bytes").
  static func bytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    // KB at the smallest, so an empty Watch reads "0 KB" in the same units as everything else.
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: max(0, value))
  }
}
