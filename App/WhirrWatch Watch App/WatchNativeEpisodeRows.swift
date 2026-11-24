import Foundation
import WatchPlayback
import WatchProtocol

/// How a row shows the download it describes: nothing, a spinner while it waits, or a bar once the
/// length is known.
enum WatchNativeEpisodeProgress: Equatable {
  case none
  case indeterminate
  case determinate(Double)
}

/// One row under On My Watch › Podcasts. Built from the store's entry and the Watch's own journal
/// so a view never decides a status or reads a store.
struct WatchNativeEpisodeRow: Identifiable, Equatable {
  enum State: Equatable {
    case ready
    case waitingToDownload
    case downloading(progress: Double?)
    case waitingForNetwork
    case failed
    case declined
  }

  let entry: WatchReceivedEpisode
  /// "1:02:00 left", "Downloading 42%" or "Not enough space on Watch".
  let status: String
  let state: State

  var id: WatchNativeSelection { entry.selection }
  var selection: WatchSelection { entry.selection.selection }
  var title: String { entry.title }
  var showTitle: String { entry.showTitle }

  var progress: WatchNativeEpisodeProgress {
    switch state {
    case .waitingToDownload:
      return .indeterminate
    case .downloading(let value):
      return value.map(WatchNativeEpisodeProgress.determinate) ?? .indeterminate
    case .ready, .waitingForNetwork, .failed, .declined:
      return .none
    }
  }

  /// A state the listener has to act on, shown in the warning colour rather than as secondary text.
  var isProblem: Bool {
    switch state {
    case .failed, .declined: return true
    case .ready, .waitingToDownload, .downloading, .waitingForNetwork: return false
    }
  }

  /// What a VoiceOver listener hears for the row: title, show and state, never a bare icon.
  var spokenLabel: String {
    WatchDisplayFormatting.metadata([title, showTitle, status])
  }
}

enum WatchNativeEpisodeRows {
  /// Newest offer first, as the store keeps them. A removed entry has no row at all.
  static func make(
    entries: [WatchReceivedEpisode], listens: [WatchNativeSelection: WatchNativeListen]
  ) -> [WatchNativeEpisodeRow] {
    entries.compactMap { entry in
      switch entry.state {
      case .removed:
        return nil
      case .ready:
        return WatchNativeEpisodeRow(
          entry: entry, status: timeLeft(entry: entry, listen: listens[entry.selection]), state: .ready)
      case .receiving:
        return WatchNativeEpisodeRow(
          entry: entry, status: "Waiting to download", state: .waitingToDownload)
      case .downloading:
        return WatchNativeEpisodeRow(
          entry: entry, status: downloading(entry.progress), state: .downloading(progress: entry.progress))
      case .waitingForNetwork:
        return WatchNativeEpisodeRow(
          entry: entry, status: "Waiting for Wi-Fi", state: .waitingForNetwork)
      case .failed:
        return WatchNativeEpisodeRow(entry: entry, status: "Couldn’t download", state: .failed)
      case .declined:
        let status =
          entry.declineReason == .storageFull
          ? "Not enough space on Watch" : "Couldn’t copy to Watch"
        return WatchNativeEpisodeRow(entry: entry, status: status, state: .declined)
      }
    }
  }

  /// "Downloading 42%", or "Downloading" until the response states a length.
  static func downloading(_ progress: Double?) -> String {
    guard let progress, progress.isFinite else { return "Downloading" }
    let percent = Int((min(max(progress, 0), 1) * 100).rounded(.down))
    return "Downloading \(percent)%"
  }

  /// The Watch's own listen and the phone's position agree on where the copy is, exactly as a
  /// resume does; a finished listen reads "Played" rather than a full duration left.
  static func timeLeft(entry: WatchReceivedEpisode, listen: WatchNativeListen?) -> String {
    if listen?.isFinished == true { return "Played" }
    guard let duration = entry.duration, duration.isFinite, duration > 0 else { return "" }
    let position = WatchNativeResumePosition.resolve(
      local: listen, phonePosition: entry.phonePosition,
      phoneLastListenedAt: entry.phoneLastListenedAt, duration: duration)
    return "\(WatchDisplayFormatting.duration(max(0, duration - position))) left"
  }
}
