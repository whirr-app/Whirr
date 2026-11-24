import Foundation
import Persistence
import SyncEngine

/// Which server setting a row reports. The view renders rows in the order `rows(...)` returns them
/// and never reorders or filters them itself, so this is also the section's row order.
public enum PodcastServerSettingsField: Sendable, Equatable, Hashable, CaseIterable {
  case autoDownloadEpisodes
  case schedule
  case newEpisodeLimit
  case retention
}

public struct PodcastServerSettingsRow: Sendable, Equatable, Identifiable {
  public let field: PodcastServerSettingsField
  public let label: String
  public let value: String

  public var id: PodcastServerSettingsField { field }

  public init(field: PodcastServerSettingsField, label: String, value: String) {
    self.field = field
    self.label = label
    self.value = value
  }
}

/// The whole read-only section, or `nil` when the server has told us nothing about this show. The
/// view renders it as-is; deciding whether the section exists is a policy question and belongs
/// here, not in a `if let` at the call site.
public struct PodcastServerSettingsSection: Sendable, Equatable {
  public let rows: [PodcastServerSettingsRow]
  public let footer: String

  public init(rows: [PodcastServerSettingsRow], footer: String) {
    self.rows = rows
    self.footer = footer
  }
}

/// The "Audiobookshelf Server" section of Show Settings, read-only. An account that may save to
/// the server gets the editor in `PodcastServerSettingsPresentation+Editor.swift` instead, which
/// is ADR 0017's one exception to API-CONVENTIONS rule 26; every other account keeps this section.
/// Pure mapping from the five server-supplied scalars to rows and a footer. It observes nothing
/// and knows nothing of this device's auto-download policy, so a server fact is never rendered as
/// a device one.
///
/// Labels are verb-led ("Downloads", "Keeps") where the device pickers above are imperative
/// ("Automatic Downloads", "Keep Latest"): device rows instruct the phone, these state what
/// another machine does. That split, not the section header alone, keeps "Keep Latest · 3" and
/// "Keeps · 10 episodes" from reading as the same setting.
///
/// The copy lives here, not in `PodcastCopy`: nothing else renders a cron expression or a server
/// retention count.
public enum PodcastServerSettingsPresentation {
  /// The label of one known Audiobookshelf schedule preset. The ordered preset list is the one
  /// source of truth: both the read-only value and the editor's choices derive from it. Anything
  /// that is not a preset renders verbatim: the user's own server produced the string, and
  /// collapsing it to "Custom" would hide what they opened the screen to find out.
  static func scheduleLabel(_ preset: PodcastAutomationSchedulePreset) -> String {
    switch preset {
    case .hourly: return "Every hour"
    case .everySixHours: return "Every 6 hours"
    case .everyTwelveHours: return "Every 12 hours"
    case .daily: return "Every day"
    case .weekly: return "Every week"
    }
  }

  /// `nil` when the server has supplied none of the five facts, since a header over an empty
  /// group claiming otherwise is worse than no section. A known last check with no known settings
  /// still earns the section: it answers "why isn't this updating?" on its own.
  public static func section(
    diagnostics: PodcastShowDiagnostics?,
    now: Date
  ) -> PodcastServerSettingsSection? {
    guard let diagnostics else { return nil }
    let rows = rows(
      autoDownloadEpisodes: diagnostics.autoDownloadEpisodes,
      autoDownloadSchedule: diagnostics.autoDownloadSchedule,
      maxNewEpisodesToDownload: diagnostics.maxNewEpisodesToDownload,
      maxEpisodesToKeep: diagnostics.maxEpisodesToKeep)
    guard rows.isEmpty == false || diagnostics.lastEpisodeCheck != nil else { return nil }
    return PodcastServerSettingsSection(
      rows: rows,
      footer: footer(lastEpisodeCheck: diagnostics.lastEpisodeCheck, now: now))
  }

  /// A nil field omits its row rather than rendering a fabricated default, except that an explicit
  /// false auto-download setting supplies the authoritative disabled state for Checks. `ItemRecord`
  /// states the rule this enforces: nil means the server did not supply the field, and no caller
  /// may infer "off" or "never" from absence.
  public static func rows(
    autoDownloadEpisodes: Bool?,
    autoDownloadSchedule: String?,
    maxNewEpisodesToDownload: Int?,
    maxEpisodesToKeep: Int?
  ) -> [PodcastServerSettingsRow] {
    var rows: [PodcastServerSettingsRow] = []
    if let autoDownloadEpisodes {
      rows.append(
        PodcastServerSettingsRow(
          field: .autoDownloadEpisodes,
          label: "Downloads New Episodes",
          value: autoDownloadEpisodes ? "On" : "Off"))
    }
    if autoDownloadEpisodes == false {
      rows.append(PodcastServerSettingsRow(field: .schedule, label: "Checks", value: "Off"))
    } else {
      if let schedule = scheduleValue(autoDownloadSchedule) {
        rows.append(
          PodcastServerSettingsRow(field: .schedule, label: "Checks", value: schedule))
      }
      if let maxNewEpisodesToDownload {
        rows.append(
          PodcastServerSettingsRow(
            field: .newEpisodeLimit,
            label: "Downloads at Most",
            value: newEpisodeLimitLabel(maxNewEpisodesToDownload)))
      }
    }
    if let maxEpisodesToKeep {
      rows.append(
        PodcastServerSettingsRow(
          field: .retention,
          label: "Keeps",
          value: retentionLabel(maxEpisodesToKeep)))
    }
    return rows
  }

  /// `nil` when the server sent nothing usable, so the caller omits the row instead of showing an
  /// empty value. A whitespace-only expression is as absent as a missing key.
  public static func scheduleValue(_ cron: String?) -> String? {
    guard let trimmed = cron?.trimmingCharacters(in: .whitespacesAndNewlines),
      trimmed.isEmpty == false
    else { return nil }
    return PodcastAutomationSchedulePreset(cronExpression: trimmed).map(scheduleLabel) ?? trimmed
  }

  /// The read-only section's footer. It names the web app: for an account that cannot save, the
  /// settings above are not editable here, so the user is pointed at where they are rather than
  /// offered a control that pretends to fix it (API-CONVENTIONS rule 26). An account that can save
  /// sees `editorFooter` instead (ADR 0017).
  public static func footer(lastEpisodeCheck: Date?, now: Date) -> String {
    let changeElsewhere = "Change these in the Audiobookshelf web app."
    guard let sentence = lastCheckedSentence(lastEpisodeCheck, now: now) else {
      return changeElsewhere
    }
    return "\(sentence). \(changeElsewhere)"
  }

  /// "Last checked 2 hours ago", shared by both footers so they can never format it differently.
  static func lastCheckedSentence(_ lastEpisodeCheck: Date?, now: Date) -> String? {
    guard let lastEpisodeCheck else { return nil }
    return PodcastCopy.lastCheckedSentence(lastEpisodeCheck, now: now)
  }

  /// A new-episode limit of zero or below is unlimited on the server.
  static func newEpisodeLimitLabel(_ count: Int) -> String {
    count > 0 ? episodeCount(count) : "No limit"
  }

  static func retentionLabel(_ count: Int) -> String {
    count > 0 ? episodeCount(count) : "All episodes"
  }

  /// Server counts are whole episodes, so the plural is the only thing that varies. Zero and below
  /// never reach here, since both callers read them as "unlimited".
  private static func episodeCount(_ count: Int) -> String {
    count == 1 ? "1 episode" : "\(count) episodes"
  }
}
