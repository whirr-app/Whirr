import Foundation

/// The account's global device-side auto-download defaults, used when no `podcastSettings` row
/// exists yet: auto-download off, keep latest 3, delete-after-played off, no cellular.
public struct PodcastGlobalSettings: Sendable, Equatable {
  public var autoDownloadEnabled: Bool
  /// `0` means "keep all", so never treat it as falsy or absent.
  public var keepLatestCount: Int
  public var deleteAfterPlayed: Bool
  public var allowCellularAutoDownload: Bool
  /// The global activation floor: non-nil once auto-download has ever been switched on.
  public var enabledAt: Date?

  public init(
    autoDownloadEnabled: Bool,
    keepLatestCount: Int,
    deleteAfterPlayed: Bool,
    allowCellularAutoDownload: Bool,
    enabledAt: Date?
  ) {
    self.autoDownloadEnabled = autoDownloadEnabled
    self.keepLatestCount = keepLatestCount
    self.deleteAfterPlayed = deleteAfterPlayed
    self.allowCellularAutoDownload = allowCellularAutoDownload
    self.enabledAt = enabledAt
  }

  /// What an absent `podcastSettings` row means. An existing install is already correct in this
  /// state the moment it migrates.
  public static let defaults = PodcastGlobalSettings(
    autoDownloadEnabled: false,
    keepLatestCount: 3,
    deleteAfterPlayed: false,
    allowCellularAutoDownload: false,
    enabledAt: nil)
}

/// A show's resolved settings, which the selection and reap queries act on, after folding the
/// tri-state override against the global defaults.
public struct PodcastEffectiveSettings: Sendable, Equatable {
  public var isEnabled: Bool
  /// `0` means "keep all".
  public var keepLatestCount: Int
  public var deleteAfterPlayed: Bool
  /// The wall-clock cutoff a candidate episode's `publishedAt` must be after. Left
  /// `.distantPast` and unread when `isEnabled` is false.
  public var floor: Date

  public init(isEnabled: Bool, keepLatestCount: Int, deleteAfterPlayed: Bool, floor: Date) {
    self.isEnabled = isEnabled
    self.keepLatestCount = keepLatestCount
    self.deleteAfterPlayed = deleteAfterPlayed
    self.floor = floor
  }
}

/// One show's full settings: its stored tri-state overrides (for editing) alongside the resolved
/// effective values (for display and for the selection/reap queries).
public struct PodcastShowSettingsDetail: Sendable, Equatable {
  public var itemID: String
  public var title: String
  public var autoDownloadOverride: PodcastShowAutoDownloadOverride
  public var keepLatestOverride: Int?
  public var deleteAfterPlayedOverride: Bool?
  public var enabledAt: Date?
  public var effective: PodcastEffectiveSettings
  /// RSS-only inbox membership. `nil` for ABS shows, whose inclusion follows its library.
  public var includeInLatest: Bool?
  /// RSS-only notification policy. `nil` for ABS shows.
  public var notificationOverride: RSSNotificationOverride?

  public init(
    itemID: String,
    title: String,
    autoDownloadOverride: PodcastShowAutoDownloadOverride,
    keepLatestOverride: Int?,
    deleteAfterPlayedOverride: Bool?,
    enabledAt: Date?,
    effective: PodcastEffectiveSettings,
    includeInLatest: Bool? = nil,
    notificationOverride: RSSNotificationOverride? = nil
  ) {
    self.itemID = itemID
    self.title = title
    self.autoDownloadOverride = autoDownloadOverride
    self.keepLatestOverride = keepLatestOverride
    self.deleteAfterPlayedOverride = deleteAfterPlayedOverride
    self.enabledAt = enabledAt
    self.effective = effective
    self.includeInLatest = includeInLatest
    self.notificationOverride = notificationOverride
  }
}

/// One row of the ordered Podcast Settings show list, enough to render "Default (Off)" / "On" /
/// "Off" without a second query per row.
public struct PodcastShowSettingsSummary: Sendable, Equatable {
  public var itemID: String
  public var title: String
  public var autoDownloadOverride: PodcastShowAutoDownloadOverride
  public var effective: PodcastEffectiveSettings

  public init(
    itemID: String,
    title: String,
    autoDownloadOverride: PodcastShowAutoDownloadOverride,
    effective: PodcastEffectiveSettings
  ) {
    self.itemID = itemID
    self.title = title
    self.autoDownloadOverride = autoDownloadOverride
    self.effective = effective
  }
}

extension PodcastShowAutoDownloadOverride {
  /// Fail-closed parse for the raw `podcastShowSettings.autoDownloadOverride` column: an unknown
  /// string becomes `disabled` without hiding the show. `PodcastShowSettingsRecord` decoded
  /// through GRDB's `FetchableRecord` throws on an unrecognised string, which would hide the row,
  /// so stores fetch the column as a plain `String` and parse it here.
  public static func parse(_ rawValue: String) -> PodcastShowAutoDownloadOverride {
    PodcastShowAutoDownloadOverride(rawValue: rawValue) ?? .disabled
  }
}

/// The only place effective-settings resolution is implemented. The selection and reap stores
/// read the raw global/show columns and call `resolve` per row rather than re-deriving the rules.
public enum PodcastEffectiveSettingsResolver {
  /// - Parameters:
  ///   - global: the account's resolved global defaults (already defaulted if no row exists).
  ///   - showOverride: the show's tri-state override, already fail-closed via
  ///     `PodcastShowAutoDownloadOverride.parse` if it came from a raw stored string.
  ///   - showKeepLatestOverride: `nil` = inherit, `0` = keep all, else the show's own count.
  ///   - showDeleteAfterPlayedOverride: `nil` = inherit.
  ///   - showEnabledAt: the show's own stamped floor, if any (nil for a show with no override
  ///     row, or one that has never transitioned effectively Off -> On on its own).
  public static func resolve(
    global: PodcastGlobalSettings,
    showOverride: PodcastShowAutoDownloadOverride,
    showKeepLatestOverride: Int?,
    showDeleteAfterPlayedOverride: Bool?,
    showEnabledAt: Date?
  ) -> PodcastEffectiveSettings {
    let isEnabled: Bool
    switch showOverride {
    case .enabled: isEnabled = true
    case .disabled: isEnabled = false
    case .inherit: isEnabled = global.autoDownloadEnabled
    }

    let floor: Date
    if !isEnabled {
      floor = .distantPast
    } else {
      switch showOverride {
      case .enabled:
        // An explicit override owns its floor; a later global change (on or off) must not move it.
        floor = showEnabledAt ?? .distantPast
      case .inherit:
        // The `max` closes the preference-race guard: a show switched back to `inherit` after an
        // Off spell gets a fresh floor, so episodes published during that spell are not
        // backfilled just because the global floor predates them.
        floor = max(global.enabledAt ?? .distantPast, showEnabledAt ?? .distantPast)
      case .disabled:
        floor = .distantPast  // unreachable: isEnabled is false whenever override is .disabled
      }
    }

    return PodcastEffectiveSettings(
      isEnabled: isEnabled,
      keepLatestCount: showKeepLatestOverride ?? global.keepLatestCount,
      deleteAfterPlayed: showDeleteAfterPlayedOverride ?? global.deleteAfterPlayed,
      floor: floor)
  }
}
