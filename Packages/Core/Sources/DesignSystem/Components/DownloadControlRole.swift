import SwiftUI

/// Which download condition a download control renders. Each case is always paired by the
/// caller with a distinct `systemImage` (as with `PlaybackStatusKind`), so
/// waiting/failed/paused/etc. are never distinguished by colour alone. Named after, but decoupled
/// from, `Persistence.ItemDownloadStatus`: this target imports no `Persistence` (see
/// ARCHITECTURE.md), so `ItemDownloadModel` maps its status to this kind at the call site.
public enum DownloadControlKind: Sendable, Equatable, CaseIterable {
  case notDownloaded
  case waitingForWiFi
  case queued
  case downloading
  case paused
  case pausedAuth
  case interrupted
  case deleting
  case failed
  case completed
}

/// What a download control's colour is saying.
///
/// The item-detail bubble inherits `.tint(accent)` from the screen, so a downloaded book's `trash`
/// glyph would take whatever colour the cover yields. The roles name what each state means, and
/// the tint table decides which meanings get a colour.
///
/// Only `warning` is coloured. Destructive states stay neutral: the confirmation dialog already
/// says it in red, no cover palette can be reconciled with a red toolbar glyph, and the bubble
/// doubles as a status readout where red reads as "something is wrong". Ordinary states stay
/// neutral too, or the inviting download arrow would be coloured and the irreversible action plain.
/// Colour therefore means one thing (something needs the listener) and every other state is
/// separated by glyph, which `DownloadControlKind` guarantees is distinct per case.
public enum DownloadControlRole: Sendable, Equatable {
  /// Invites or reports an ordinary transfer.
  case ordinary
  /// Removes something already on the device.
  case destructive
  /// Needs attention before the transfer can continue.
  case warning

  public static func role(for kind: DownloadControlKind) -> DownloadControlRole {
    switch kind {
    case .completed, .deleting:
      return .destructive
    case .failed, .interrupted, .pausedAuth:
      return .warning
    case .notDownloaded, .waitingForWiFi, .queued, .downloading, .paused:
      return .ordinary
    }
  }

  /// The colour for a control kind. Neutral ink for everything the app can carry out or undo on
  /// its own, orange for the states that need the listener before the transfer can continue.
  /// `ShellStatusIndicatorView` uses the same orange for "needs attention, nothing is broken".
  public static func tint(for kind: DownloadControlKind) -> Color {
    switch role(for: kind) {
    case .ordinary, .destructive: return .primary
    case .warning: return .orange
    }
  }
}
