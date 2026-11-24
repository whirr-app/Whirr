import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// How the toolbar download bubble reacts to a tap, derived from the item-level
/// `DownloadControlKind` plus the mixed-format projection. A pure derivation tested without
/// rendering, like `ChapterSelectorPresentation`. `ItemDetailView` switches over this to decide
/// whether a tap performs the primary action, opens a menu, or opens a destructive confirmation,
/// and never re-derives the mapping.
nonisolated enum ItemDetailDownloadBubblePresentation {
  enum DownloadOption: Hashable {
    case audio
    case ebook
    case both

    var format: ItemDownloadFormat {
      switch self {
      case .audio: .audio
      case .ebook: .ebook
      case .both: .both
      }
    }

    /// Owned by `ItemDownloadCopy` because the row long-press menu offers the same three choices
    /// and the two surfaces must name them identically.
    var label: String { ItemDownloadCopy.formatLabel(for: format) }
  }

  nonisolated enum SymbolMotion: Equatable {
    case replace
    case immediate

    var transition: ContentTransition {
      switch self {
      case .replace: .symbolEffect(.replace)
      case .immediate: .identity
      }
    }
  }

  nonisolated static func symbolMotion(reduceMotion: Bool) -> SymbolMotion {
    reduceMotion ? .immediate : .replace
  }

  /// What tapping the bubble does for a given `DownloadControlKind`.
  nonisolated enum TapBehavior: Equatable {
    /// Tapping performs the primary action immediately, with no menu or confirmation. Covers
    /// "tap to download" and the paused-family "tap to resume" for single-format items.
    case direct
    /// Tapping opens a menu offering the primary action, plus a destructive secondary action
    /// when one exists. Covers the in-flight states (downloading/waiting/queued).
    case menu
    /// Tapping opens a destructive confirmation dialog before removing a completed download.
    case confirm
    /// The bubble does not respond to taps (the mid-removal `deleting` state).
    case disabled
  }

  static func tapBehavior(for kind: DownloadControlKind) -> TapBehavior {
    switch kind {
    case .notDownloaded, .paused, .pausedAuth, .interrupted, .failed:
      return .direct
    case .waitingForWiFi, .queued, .downloading:
      return .menu
    case .completed:
      return .confirm
    case .deleting:
      return .disabled
    }
  }

  /// The format-specific entries to show in a mixed audiobook's menu. Separate from
  /// `DownloadControlKind`, which describes the item's aggregate transfer state, whereas these
  /// describe which media kinds have a completed local row.
  static func downloadOptions(
    for status: ItemDownloadStatus,
    formatStatus: ItemFormatDownloadStatus,
    category: ItemMediaCategory,
    hasReadableEbook: Bool
  ) -> [DownloadOption] {
    guard category == .audiobook, hasReadableEbook else { return [] }

    switch status {
    case .notDownloaded:
      guard formatStatus.audio == .notDownloaded, formatStatus.ebook == .notDownloaded else {
        return []
      }
      return [.audio, .ebook, .both]
    case .completed:
      if formatStatus.audio == .completed, formatStatus.ebook == .notDownloaded {
        return [.ebook]
      }
      if formatStatus.audio == .notDownloaded, formatStatus.ebook == .completed {
        return [.audio]
      }
      return []
    case .waitingForWiFi, .queued, .downloading, .paused, .pausedAuth, .interrupted, .deleting,
      .failed:
      return []
    }
  }

  /// Mixed-format state can turn the otherwise direct not-downloaded control, or the otherwise
  /// confirmation-only completed control, into a menu. Every other state follows the item-level
  /// behaviour.
  static func tapBehavior(
    for kind: DownloadControlKind,
    status: ItemDownloadStatus,
    formatStatus: ItemFormatDownloadStatus,
    category: ItemMediaCategory,
    hasReadableEbook: Bool
  ) -> TapBehavior {
    downloadOptions(
      for: status, formatStatus: formatStatus, category: category, hasReadableEbook: hasReadableEbook
    ).isEmpty
      ? tapBehavior(for: kind)
      : .menu
  }

  /// A mixed partial download keeps the completed item's destructive action beside its
  /// missing-format entry. The ordinary in-flight menu takes its labels from
  /// `ItemDetailViewPresentation`.
  static func formatMenuRemoveLabel(
    for kind: DownloadControlKind, options: [DownloadOption]
  ) -> String? {
    guard options.isEmpty == false, kind == .completed else { return nil }
    return primaryActionLabel(for: kind)
  }

  /// Whether a `.direct` bubble should also expose a secondary "Remove" action. Paused-family
  /// states have an in-flight download to remove; `notDownloaded` has nothing yet, so it offers
  /// only "Download".
  static func exposesSecondaryRemove(for kind: DownloadControlKind) -> Bool {
    tapBehavior(for: kind) == .direct && kind != .notDownloaded
  }

  /// The glyph inside the toolbar bubble. An active transfer pairs its determinate progress ring
  /// with a download glyph, since tapping opens a menu and a pause glyph in the ring would imply
  /// the tap pauses immediately. Completion is a trash glyph so the offline state and its
  /// deletion affordance are unmistakable.
  ///
  /// Every glyph is unenclosed: an enclosed symbol such as `arrow.down.circle` draws its mark
  /// small, a size under its toolbar neighbours (bookmark, trash, ellipsis), and
  /// `DownloadProgressRing` draws its own ring. Menus keep circled forms
  /// (`ItemContextMenuPresentation.downloadEntry`).
  static func systemImage(for kind: DownloadControlKind) -> String? {
    switch kind {
    case .notDownloaded: return "arrow.down"
    case .waitingForWiFi: return "wifi.slash"
    case .queued: return "clock"
    case .downloading: return "arrow.down"
    case .paused: return "play.fill"
    case .pausedAuth: return "lock"
    case .interrupted: return "arrow.clockwise"
    case .deleting: return "trash.slash"
    case .failed: return "exclamationmark.triangle"
    case .completed: return "trash"
    }
  }

  /// Whether a glyph is drawn enclosed in a ring or dot, which the toolbar group cannot tolerate.
  /// Exists so the contract above can be tested.
  static func isEnclosed(_ systemImage: String) -> Bool {
    systemImage.hasSuffix(".circle") || systemImage.hasSuffix(".circle.fill")
      || systemImage.hasSuffix(".square") || systemImage.hasSuffix(".square.fill")
  }

  /// Describes what tapping an in-flight control actually does. The action-specific hint belongs
  /// to the menu item, not its presenting ring.
  static func menuAccessibilityHint(for kind: DownloadControlKind) -> String {
    switch kind {
    case .downloading:
      return "Shows options to pause or remove this download."
    case .waitingForWiFi, .queued:
      return "Shows an option to cancel this download."
    case .notDownloaded, .paused, .pausedAuth, .interrupted, .deleting, .failed, .completed:
      return ""
    }
  }

  /// The action name for each state, kept beside the icon mapping so a completed transfer cannot
  /// retain the active transfer's "Pause" action.
  static func primaryActionLabel(for kind: DownloadControlKind) -> String {
    switch kind {
    case .notDownloaded: return MediaActionCopy.download.title
    case .waitingForWiFi, .queued: return "Cancel"
    case .downloading: return "Pause"
    case .paused, .pausedAuth, .interrupted, .failed: return "Resume"
    case .deleting: return "Removing"
    case .completed: return MediaActionCopy.removeDownload.title
    }
  }
}
