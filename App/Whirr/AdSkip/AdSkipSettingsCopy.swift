import AppModel
import SwiftUI

/// Copy for the Reduce Ads setting. It sets expectations from the evidence: fewer ads, not none,
/// and never a promise that only ads are skipped.
enum AdSkipSettingsCopy {
  static let title = "Reduce Ads"
  static let on = "On"
  static let off = "Off"
  static let rowSummary = "Skips ads in downloaded episodes"
  static let onlyWhileCharging = "Only While Charging"

  static let goodToKnow = "Good to Know"
  static let onDeviceTitle = "Runs on this iPhone"
  static let onDeviceDetail =
    "Whirr compares downloaded episodes here, looking for audio that repeats. No audio or "
    + "transcript leaves it."
  static let downloadedOnlyTitle = "Downloaded episodes only"
  static let downloadedOnlyDetail = "Streamed episodes aren’t analysed. English-language shows only."
  static let autoDownloadsTitle = "Automatic Downloads help"
  static let autoDownloadsDetail =
    "The more Whirr has heard, the more it can skip. With automatic downloads on, each new "
    + "episode adds to what it’s learned."
  static let batteryTitle = "Uses battery"
  static let batteryDetail =
    "Analysing a large batch of episodes can use noticeable power. Only While Charging limits "
    + "this to when the iPhone is plugged in."
  /// What to expect, privacy first: the first row carries both what the feature does and the
  /// claim that it stays on the phone.
  static let goodToKnowRows: [(title: String, detail: String?, systemImage: String)] = [
    (onDeviceTitle, onDeviceDetail, "iphone"),
    (downloadedOnlyTitle, downloadedOnlyDetail, "arrow.down.circle"),
    (autoDownloadsTitle, autoDownloadsDetail, "arrow.triangle.2.circlepath"),
    (batteryTitle, batteryDetail, "bolt.batteryblock"),
  ]

  static let howItWorks = "How It Works"
  static let repeatsTitle = "Finds what repeats"
  static let repeatsDetail =
    "Whirr takes an audio print of each downloaded episode and looks for stretches that also turn "
    + "up in other episodes."
  static let transcribesTitle = "Transcribes those parts"
  static let transcribesDetail = "Apple’s speech model transcribes only the stretches that repeat."
  static let decidesTitle = "Decides what’s an ad"
  static let decidesDetail =
    "An on-device text classifier scores each transcript as ad or show. Ads are remembered and "
    + "skipped wherever they turn up next."
  /// In-context copy for the How It Works rows, which live behind a disclosure.
  static let howItWorksRows: [(title: String, detail: String?, systemImage: String)] = [
    (repeatsTitle, repeatsDetail, "waveform"),
    (transcribesTitle, transcribesDetail, "text.quote"),
    (decidesTitle, decidesDetail, "checklist"),
  ]

  static let whenItGetsItWrong = "When It Gets It Wrong"
  static let newAdsTitle = "New ads"
  static let newAdsDetail = "Whirr can only skip an ad it has heard in another episode."
  static let hostReadTitle = "Host-read sponsor messages"
  static let hostReadDetail =
    "Most aren’t caught. Transcribing the episode finds more, usually where the host reads out "
    + "a web address."
  static let markAdsTitle = "Mark ads yourself"
  static let markAdsDetail =
    "In its transcript, mark a stretch as an ad, or tap Not an ad on one Whirr skipped. A "
    + "marked ad can be remembered for other episodes."
  static let repeatedTitle = "Repeated intros, credits and promos"
  static let repeatedDetail =
    "Tap Undo in the player, or Not an ad in the transcript, and that stretch won’t be skipped "
    + "again."
  /// Missed ads first, with the host-read miss answered by the two rows beneath it, then the
  /// over-skips that Undo takes back.
  static let whenItGetsItWrongRows: [(title: String, detail: String?, systemImage: String)] = [
    (newAdsTitle, newAdsDetail, "plus.circle"),
    (hostReadTitle, hostReadDetail, "person.wave.2"),
    (markAdsTitle, markAdsDetail, "megaphone"),
    (repeatedTitle, repeatedDetail, "arrow.uturn.backward"),
  ]

  static let downloadTitle = "Download the English speech model?"
  static let downloadMessage =
    "Reduce Ads transcribes episodes on this iPhone with Apple’s speech model. Nothing else is "
    + "sent or received."
  static let downloadOnWiFi = "Download on Wi-Fi"
  static let downloadNow = "Download Now"
  static let download = "Download Speech Model"
  static let cancel = "Cancel"
  static let waitingForWiFi = "Waiting for Wi-Fi…"
  static let downloading = "Downloading speech model…"
  static let failed = "The speech model could not be downloaded."
  static let retry = "Try Again"
  static let forget = "Forget Learned Ads"
  static let forgetTitle = "Forget learned ads?"
  static let forgetMessage =
    "Ads already heard will be skipped again only after they are heard in another episode. Skips you undid are "
    + "forgotten too. Restoring an older backup brings learned ads back."
}

/// The progress line on the Reduce Ads page.
enum AdSkipProgressCopy {
  struct Status: Equatable {
    var title: String
    var detail: String?
  }

  nonisolated static func status(
    for progress: AdSkipProgress, pauseReason: AdSkipPauseReason? = nil
  ) -> Status {
    guard progress.total > 0 else {
      return Status(title: "No downloaded episodes to analyse", detail: nil)
    }
    let noun = progress.total == 1 ? "episode" : "episodes"
    var details: [String] = []
    switch progress.activity {
    case .analysing: details.append(progress.remaining > 0 ? "Analysing…" : checkingDetail)
    case .paused: details.append(pausedDetail(pauseReason))
    case .idle: break
    }
    if progress.unanalysable > 0 {
      details.append("\(progress.unanalysable) couldn’t be analysed")
    }
    return Status(
      title: "\(progress.analysed) of \(progress.total) \(noun) analysed",
      detail: details.isEmpty ? nil : details.joined(separator: " · "))
  }
}

extension AdSkipProgressCopy {
  /// Every episode counts, but some still have stretches to transcribe: a later download made
  /// more of their audio recur, or a newly learned ad did.
  nonisolated static let checkingDetail = "Checking for more ads…"

  /// Without a reason the conditions allow analysis, so the pause is the coordinator's own: the
  /// speech model is still to arrive, or a background run ran out of time.
  nonisolated static func pausedDetail(_ reason: AdSkipPauseReason?) -> String {
    guard let reason else { return "Paused" }
    return AdSkipWaitPresentation.settingsDetail(reason)
  }
}

extension AdSkipSettingsCopy {
  /// The detail line on the root Settings row: one short line saying what the feature is doing
  /// now, so its background cost is visible without opening the page. Off, or on with nothing yet
  /// heard from the coordinator, it says what the feature is.
  static func rowDetail(
    isEnabled: Bool, asset: AdSkipSettingsModel.Asset, progress: AdSkipProgress?,
    pauseReason: AdSkipPauseReason?
  ) -> String {
    guard isEnabled else { return rowSummary }
    switch asset {
    case .notInstalled: return "Speech model needed"
    case .waitingForWiFi: return waitingForWiFi
    case .downloading: return downloading
    case .failed: return "Speech model download failed"
    case .checking, .unavailable, .installed: break
    }
    guard let progress else { return rowSummary }
    guard progress.total > 0 else { return AdSkipProgressCopy.status(for: progress).title }
    let count = "\(progress.analysed) of \(progress.total) episodes"
    switch progress.activity {
    case .analysing:
      return progress.remaining > 0 ? "Analysing \(count)" : "Checking \(count) for more ads"
    case .paused:
      if let pauseReason { return AdSkipProgressCopy.pausedDetail(pauseReason) }
      return "Paused after \(count)"
    case .idle:
      return AdSkipProgressCopy.status(for: progress).title
    }
  }
}
