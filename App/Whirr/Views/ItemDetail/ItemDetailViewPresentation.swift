import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

enum ItemDetailViewPresentation {
  nonisolated enum FinishedBadgeMotion: Equatable {
    case scaleAndFade
    case fadeOnly

    var transition: AnyTransition {
      switch self {
      case .scaleAndFade: .scale(scale: 0.6).combined(with: .opacity)
      case .fadeOnly: .opacity
      }
    }

    var animation: Animation? {
      switch self {
      case .scaleAndFade: .spring(response: 0.32, dampingFraction: 0.72)
      case .fadeOnly: .easeInOut(duration: 0.2)
      }
    }
  }

  nonisolated static func finishedBadgeMotion(reduceMotion: Bool) -> FinishedBadgeMotion {
    reduceMotion ? .fadeOnly : .scaleAndFade
  }

  static func controlKind(for status: ItemDownloadStatus) -> DownloadControlKind {
    switch status {
    case .notDownloaded: return .notDownloaded
    case .waitingForWiFi: return .waitingForWiFi
    case .queued: return .queued
    case .downloading: return .downloading
    case .paused: return .paused
    case .pausedAuth: return .pausedAuth
    case .interrupted: return .interrupted
    case .deleting: return .deleting
    case .failed: return .failed
    case .completed: return .completed
    }
  }

  static func progressFraction(for status: ItemDownloadStatus) -> Double? {
    if case .downloading(let fraction) = status { return fraction }
    return nil
  }

  static func primaryActionHint(for kind: DownloadControlKind) -> String {
    switch kind {
    case .notDownloaded: return "Starts downloading this title for offline listening."
    case .waitingForWiFi, .queued: return "Cancels this download."
    case .downloading: return "Pauses this download."
    case .paused, .interrupted, .failed: return "Resumes this download."
    case .pausedAuth: return "Sign in again to resume this download."
    case .deleting: return ""
    case .completed: return "Removes the downloaded file from this device."
    }
  }

  static func secondaryActionLabel(for kind: DownloadControlKind) -> String? {
    switch kind {
    case .downloading, .paused, .pausedAuth, .interrupted, .failed: return "Remove"
    case .notDownloaded, .waitingForWiFi, .queued, .deleting, .completed: return nil
    }
  }

  /// Built once: the hero and the Details section both format the same duration on every body
  /// evaluation, and `DateComponentsFormatter` is expensive to construct.
  private static let durationFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  /// Rounded to the nearest minute, as `ItemDetailPlayButtonPresentation.remainingLabel` is: the
  /// formatter alone drops the leftover seconds, so the two disagreed on short titles.
  static func formattedDuration(_ seconds: Double) -> String {
    durationFormatter.string(from: (seconds / 60).rounded() * 60) ?? ""
  }
}
