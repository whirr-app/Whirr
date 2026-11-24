import Foundation
import Persistence

/// User-facing copy for the device-side podcast auto-download feature. Distinct from
/// `PodcastCopy`'s `autoDownloadOn`/`autoDownloadOff`, which name the server's read-only RSS
/// setting. Device controls name episodes directly and never use the bare phrase
/// "Auto-download", so the two concepts cannot be confused.
public enum PodcastDownloadCopy {
  public static let autoDownloadToggleTitle = "Download New Episodes"
  public static let allowCellularToggleTitle = "Use Cellular for New Episodes"
  public static let actionFailed = "Couldn't update podcast settings. Try again."
  public static let showSettingsNotFound = "This show is no longer available."

  public static let onLabel = "On"
  public static let offLabel = "Off"
  public static let allLabel = "All"

  /// Wraps an inherited value so it never renders as a bare "Default": "Default (3)".
  public static func defaultLabel(_ inner: String) -> String { "Default (\(inner))" }

  /// The show-detail picker distinguishes inherited values from explicit overrides.
  public static func autoDownloadOverrideLabel(
    _ override: PodcastShowAutoDownloadOverride, effectiveIsEnabled: Bool
  ) -> String {
    switch override {
    case .inherit: defaultLabel(effectiveIsEnabled ? onLabel : offLabel)
    case .enabled: onLabel
    case .disabled: offLabel
    }
  }

  /// The show list marks deviation, not state: an inheriting row gets no label. The value comes
  /// from the override itself, since `effective` derives from it whenever it is not `.inherit`.
  public static func showRowLabel(_ row: PodcastShowSettingsSummary) -> String? {
    switch row.autoDownloadOverride {
    case .inherit: nil
    case .enabled: "Downloads on"
    case .disabled: "Downloads off"
    }
  }

  /// Each download-defaults section names its source and that episodes land on this device. The
  /// Downloads screen shows one section per source with shows, so each must say what it governs.
  public static let directDefaultsFooter =
    "Downloads to this device for podcasts you follow directly in Whirr. Individual shows can override these settings."
  public static let serverDefaultsFooter =
    "Downloads to this device for Audiobookshelf podcasts. Individual shows can override these settings."

  /// `0` is "keep all" everywhere in this feature, rendered as "All", never "0".
  public static func keepLatestValueLabel(_ count: Int) -> String {
    count == 0 ? allLabel : "\(count)"
  }

  public static func keepLatestOverrideLabel(_ override: Int?, effectiveCount: Int) -> String {
    if let override {
      keepLatestValueLabel(override)
    } else {
      defaultLabel(keepLatestValueLabel(effectiveCount))
    }
  }

  public static func deleteAfterPlayedOverrideLabel(
    _ override: Bool?, effectiveValue: Bool
  ) -> String {
    if let override {
      override ? onLabel : offLabel
    } else {
      defaultLabel(effectiveValue ? onLabel : offLabel)
    }
  }

  /// The show screen's one-line state hint: what an effectively-on show does to this device.
  /// The caller (`PodcastShowSettingsModel.stateHint`) gates this on `effective.isEnabled`; this
  /// only renders the "on" text.
  public static func keepLatestStateHint(count: Int) -> String {
    count == 0
      ? "Keeping new episodes on this device"
      : "Keeping \(count) newest on this device"
  }
}
