import Foundation
import Persistence
import SyncEngine

/// One option in an editor picker.
public struct PodcastServerSettingsChoice<Value: Sendable & Hashable>: Sendable, Hashable,
  Identifiable
{
  public let value: Value
  public let label: String

  public var id: Value { value }

  public init(value: Value, label: String) {
    self.value = value
    self.label = label
  }
}

/// A schedule the editor can show. Only `.preset` is ever sent; `.stored` exists so a custom
/// schedule the server already holds can be displayed as the current choice, verbatim, until a
/// preset replaces it.
public enum PodcastServerScheduleChoice: Sendable, Hashable {
  case preset(PodcastAutomationSchedulePreset)
  case stored(String)
}

/// One picker: its choices in display order and the choice that is current. `selection` is `nil`
/// only for a schedule the server holds no value for, which shows nothing selected.
public struct PodcastServerSettingsPicker<Value: Sendable & Hashable>: Sendable, Equatable {
  public let label: String
  public let choices: [PodcastServerSettingsChoice<Value>]
  public let selection: Value?

  public init(
    label: String, choices: [PodcastServerSettingsChoice<Value>], selection: Value?
  ) {
    self.label = label
    self.choices = choices
    self.selection = selection
  }
}

/// ADR 0017: the "Audiobookshelf Server" section for an account that may save to the server. A
/// control exists only for a field the server supplied; nothing here is a default. Built from the
/// same stored diagnostics as the read-only section and shown instead of it, never beside it.
public struct PodcastServerSettingsEditor: Sendable, Equatable {
  /// `nil` when the server did not supply the setting, so no toggle is offered.
  public let downloadsNewEpisodes: Bool?
  public let schedule: PodcastServerSettingsPicker<PodcastServerScheduleChoice>?
  public let newEpisodeLimit: PodcastServerSettingsPicker<Int>?
  public let retention: PodcastServerSettingsPicker<Int>?
  public let footer: String

  public static let downloadsNewEpisodesLabel = "Downloads New Episodes"

  public init(
    downloadsNewEpisodes: Bool?,
    schedule: PodcastServerSettingsPicker<PodcastServerScheduleChoice>?,
    newEpisodeLimit: PodcastServerSettingsPicker<Int>?,
    retention: PodcastServerSettingsPicker<Int>?,
    footer: String
  ) {
    self.downloadsNewEpisodes = downloadsNewEpisodes
    self.schedule = schedule
    self.newEpisodeLimit = newEpisodeLimit
    self.retention = retention
    self.footer = footer
  }

  var hasControls: Bool {
    downloadsNewEpisodes != nil || schedule != nil || newEpisodeLimit != nil || retention != nil
  }
}

extension PodcastServerSettingsPresentation {
  /// Downloads at Most. `0` is the server's "unlimited" and is not offered: Whirr never sends it.
  public static let newEpisodeLimitChoices = [1, 2, 3, 5, 10]
  /// Keeps. `0` is "All episodes".
  public static let retentionChoices = [0, 1, 2, 3, 5, 10, 25, 50]

  public static let editorFooterSentence =
    "Changes apply on the server, for everyone who uses it. A Keeps limit also removes episodes saved by hand."

  /// The editor's footer: the last check when known, then the one fact the controls above cannot
  /// say for themselves. It does not name the web app.
  public static func editorFooter(lastEpisodeCheck: Date?, now: Date) -> String {
    guard let sentence = lastCheckedSentence(lastEpisodeCheck, now: now) else {
      return editorFooterSentence
    }
    return "\(sentence). \(editorFooterSentence)"
  }

  /// `nil` when there is nothing to edit (no diagnostics, or none of the controllable fields
  /// supplied), so the caller falls back to the read-only section, which reports a last check.
  ///
  /// Checks and Downloads at Most exist only while downloads are known to be on, as in the
  /// read-only section. A server schedule that is not a preset is the current choice, verbatim; an
  /// empty one leaves nothing selected.
  public static func editor(
    diagnostics: PodcastShowDiagnostics?,
    now: Date
  ) -> PodcastServerSettingsEditor? {
    guard let diagnostics else { return nil }
    let downloadsOn = diagnostics.autoDownloadEpisodes == true

    var schedule: PodcastServerSettingsPicker<PodcastServerScheduleChoice>?
    if downloadsOn {
      var choices = PodcastAutomationSchedulePreset.allCases.map {
        PodcastServerSettingsChoice(
          value: PodcastServerScheduleChoice.preset($0), label: scheduleLabel($0))
      }
      var selection: PodcastServerScheduleChoice?
      if let trimmed = diagnostics.autoDownloadSchedule?
        .trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false
      {
        if let preset = PodcastAutomationSchedulePreset(cronExpression: trimmed) {
          selection = .preset(preset)
        } else {
          let custom = PodcastServerScheduleChoice.stored(trimmed)
          choices.append(PodcastServerSettingsChoice(value: custom, label: trimmed))
          selection = custom
        }
      }
      schedule = PodcastServerSettingsPicker(
        label: "Checks", choices: choices, selection: selection)
    }

    let newEpisodeLimit: PodcastServerSettingsPicker<Int>? =
      downloadsOn
      ? diagnostics.maxNewEpisodesToDownload.map {
        countPicker(
          label: "Downloads at Most", offered: newEpisodeLimitChoices, current: $0,
          labelFor: newEpisodeLimitLabel)
      } : nil
    let retention = diagnostics.maxEpisodesToKeep.map {
      countPicker(
        label: "Keeps", offered: retentionChoices, current: $0, labelFor: retentionLabel)
    }

    let editor = PodcastServerSettingsEditor(
      downloadsNewEpisodes: diagnostics.autoDownloadEpisodes,
      schedule: schedule,
      newEpisodeLimit: newEpisodeLimit,
      retention: retention,
      footer: editorFooter(lastEpisodeCheck: diagnostics.lastEpisodeCheck, now: now))
    return editor.hasControls ? editor : nil
  }

  /// The fixed choices, plus the stored value as an extra current choice when it is not one of them
  /// (including a new-episode limit of `0`, "No limit"). It sits in numeric order and disappears
  /// once a listed value replaces it, because it is derived from the stored value on every build.
  private static func countPicker(
    label: String, offered: [Int], current: Int, labelFor: (Int) -> String
  ) -> PodcastServerSettingsPicker<Int> {
    let values = offered.contains(current) ? offered : (offered + [current]).sorted()
    return PodcastServerSettingsPicker(
      label: label,
      choices: values.map { PodcastServerSettingsChoice(value: $0, label: labelFor($0)) },
      selection: current)
  }
}

/// Inline outcomes of a server write. They live beside the presentation because every string is a
/// property of this one section.
public enum PodcastServerSettingsMessage {
  /// Shown under the server header, with no editor, for a followed feed that matches
  /// more than one show on the server.
  public static let severalCopies =
    "This podcast has more than one copy on the server. Change its settings in the Audiobookshelf web app."

  public static let savedPendingRefresh =
    "Saved on the server. This screen will update after the next refresh."
  public static let unconfirmed =
    "The change could not be confirmed. Showing the server's last known settings."
  public static let accountCannotChange = "This account can no longer change server settings."
  public static let showMissing = "This show is no longer on the server."
  public static let unreachable = "The server could not be reached. Nothing was changed on this device."
  public static let notAccepted = "The server did not accept the change."
}
