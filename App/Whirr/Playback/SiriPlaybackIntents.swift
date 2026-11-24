import AppIntents
import Foundation
import WidgetProtocol

// Compiled into Whirr and WhirrWidgetsExtension, so it may import only frameworks and the
// extension's own package products. Every `perform()` hands off to `SiriPlaybackIntentPerformer`,
// defined per target: the app's runs the account router; the extension's refuses, as the system
// performs these intents in the app process. Unlike a launch-time hook, it cannot be missing.

/// What an intent asks the app to do. Payload-free apart from the finite sleep-timer choice.
nonisolated enum SiriPlaybackIntentAction: Sendable, Equatable {
  case resume
  case pause
  case skipForward
  case skipBack
  case setSleepTimer(SiriSleepTimerDuration)
  case extendSleepTimer
  /// A widget row's opaque token, resolved by the app's own token map, never a server ID.
  case playWidgetItem(token: String)
  /// A smart list widget row's token: starts that list's run from the row's episode.
  case playSmartListItem(token: String)
}

/// Payload-free App Intents copy. Core returns only these finite availability states, so no
/// private playback metadata can cross into a Siri error or dialog accidentally.
nonisolated enum SiriPlaybackIntentResponse: Equatable {
  case resuming
  case paused
  case skippedForward
  case skippedBack
  case sleepTimerSet(SiriSleepTimerDuration)
  case sleepTimerCancelled
  case sleepTimerExtended
  case accountUnavailable
  case noBookmark
  case noActivePlayback
  case noChapters
  case startFailed
  case itemUnavailable
  case noSleepTimer

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .resuming: "Resuming playback."
    case .paused: "Playback paused."
    case .skippedForward: "Skipped forward."
    case .skippedBack: "Skipped back."
    case .sleepTimerSet(let duration):
      switch duration {
      case .off: "Sleep timer cancelled."
      case .fifteenMinutes: "Sleep timer set for 15 minutes."
      case .thirtyMinutes: "Sleep timer set for 30 minutes."
      case .fortyFiveMinutes: "Sleep timer set for 45 minutes."
      case .sixtyMinutes: "Sleep timer set for 60 minutes."
      case .endOfChapter: "Playback will stop at the end of the chapter."
      }
    case .sleepTimerCancelled: "Sleep timer cancelled."
    case .sleepTimerExtended: "Sleep timer extended by 15 minutes."
    case .accountUnavailable: "Sign in to Whirr, then try again."
    case .noBookmark: "There’s no recent playback yet."
    case .noActivePlayback: "Nothing is playing."
    case .noChapters: "The current item has no chapters."
    case .startFailed: "Playback couldn’t start. Check your connection and try again."
    case .itemUnavailable: "That title isn’t available."
    case .noSleepTimer: "No sleep timer is running."
    }
  }

  func throwIfUnavailable() throws {
    switch self {
    case .resuming, .paused, .skippedForward, .skippedBack, .sleepTimerSet(_),
      .sleepTimerCancelled, .sleepTimerExtended:
      return
    case .accountUnavailable, .noBookmark, .noActivePlayback, .noChapters, .startFailed,
      .itemUnavailable, .noSleepTimer:
      throw SiriPlaybackIntentError(response: self)
    }
  }
}

/// A localizable thrown error lets successful transport controls return without spoken dialogue,
/// while Siri and Shortcuts still get a short, actionable explanation for every unavailable path.
nonisolated private struct SiriPlaybackIntentError: Error, CustomLocalizedStringResourceConvertible {
  let response: SiriPlaybackIntentResponse

  var localizedStringResource: LocalizedStringResource { response.localizedStringResource }
}

/// Every action directly conforms to `AudioPlaybackIntent`, so the system can avoid interrupting
/// the audio it controls. The explicit background/lock policy is repeated on each action because
/// App Intent policy is per intent: these controls expose no title, author, account, server,
/// library, or position and mirror the controls already available on the lock screen.
struct ResumeListeningIntent: AudioPlaybackIntent {
  static let persistentIdentifier = "resume-listening"
  static let title: LocalizedStringResource = "Resume Listening"
  static let description = IntentDescription(
    "Resume the most recent playback in Whirr.")
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.resume).throwIfUnavailable()
    return .result()
  }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
  static let persistentIdentifier = "pause-playback"
  static let title: LocalizedStringResource = "Pause Playback"
  static let description = IntentDescription("Pause Whirr playback.")
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.pause).throwIfUnavailable()
    return .result()
  }
}

struct SkipForwardIntent: AudioPlaybackIntent {
  static let persistentIdentifier = "skip-forward"
  static let title: LocalizedStringResource = "Skip Forward"
  static let description = IntentDescription(
    "Skip forward by the interval selected in Whirr settings.")
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.skipForward).throwIfUnavailable()
    return .result()
  }
}

struct SkipBackIntent: AudioPlaybackIntent {
  static let persistentIdentifier = "skip-back"
  static let title: LocalizedStringResource = "Skip Back"
  static let description = IntentDescription(
    "Skip back by the interval selected in Whirr settings.")
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.skipBack).throwIfUnavailable()
    return .result()
  }
}

enum SiriSleepTimerDuration: String, AppEnum, CaseIterable {
  case off
  case fifteenMinutes = "15-minutes"
  case thirtyMinutes = "30-minutes"
  case fortyFiveMinutes = "45-minutes"
  case sixtyMinutes = "60-minutes"
  case endOfChapter = "end-of-chapter"

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer Duration")
  static let caseDisplayRepresentations: [SiriSleepTimerDuration: DisplayRepresentation] = [
    .off: DisplayRepresentation(
      title: "Off", synonyms: ["Cancel", "No timer"]),
    .fifteenMinutes: DisplayRepresentation(
      title: "15 minutes", synonyms: ["Fifteen minutes"]),
    .thirtyMinutes: DisplayRepresentation(
      title: "30 minutes", synonyms: ["Thirty minutes", "Half an hour"]),
    .fortyFiveMinutes: DisplayRepresentation(
      title: "45 minutes", synonyms: ["Forty-five minutes"]),
    .sixtyMinutes: DisplayRepresentation(
      title: "60 minutes", synonyms: ["Sixty minutes", "One hour"]),
    .endOfChapter: DisplayRepresentation(
      title: "End of Chapter", synonyms: ["The end of this chapter"]),
  ]

  /// The response for a performed request: the duration actually set, or the cancellation.
  var successResponse: SiriPlaybackIntentResponse {
    self == .off ? .sleepTimerCancelled : .sleepTimerSet(self)
  }
}

struct SetSleepTimerIntent: AudioPlaybackIntent {
  static let persistentIdentifier = "set-sleep-timer"
  static let title: LocalizedStringResource = "Set Sleep Timer"
  static let description = IntentDescription("Set or cancel Whirr’s playback sleep timer.")
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(
    title: "Duration",
    description: "When playback should stop.",
    default: .thirtyMinutes,
    requestValueDialog: "For how long?"
  )
  var duration: SiriSleepTimerDuration

  static var parameterSummary: some ParameterSummary {
    Summary("Set the sleep timer to \(\.$duration)")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let response = await SiriPlaybackIntentPerformer.perform(.setSleepTimer(duration))
    try response.throwIfUnavailable()
    return .result(dialog: IntentDialog(response.localizedStringResource))
  }
}

/// The Sleep control's action. A `LiveActivityIntent` may start the sleep-timer Live Activity from
/// the background; Siri keeps `SetSleepTimerIntent`. Not discoverable: it exists for the control,
/// which offers the same finite choices.
struct StartSleepTimerIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Start Sleep Timer"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Duration", default: .thirtyMinutes)
  var duration: SiriSleepTimerDuration

  init() {}

  init(duration: SiriSleepTimerDuration) {
    self.duration = duration
  }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.setSleepTimer(duration)).throwIfUnavailable()
    return .result()
  }
}

/// The sleep-timer Live Activity's +15 button. PlayerCore extends a countdown only.
struct ExtendSleepTimerIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Extend Sleep Timer"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  /// Matches the "Sleep timer extended by 15 minutes." confirmation.
  static let extensionSeconds: Double = 15 * 60

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.extendSleepTimer).throwIfUnavailable()
    return .result()
  }
}

/// The sleep-timer Live Activity's Cancel button.
struct CancelSleepTimerIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Cancel Sleep Timer"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.setSleepTimer(.off)).throwIfUnavailable()
    return .result()
  }
}

/// A widget row's play button. The token is the row's opaque handle from the widget snapshot; the
/// app resolves it through its private token map, so an unknown, stale or other-account token is
/// refused as unavailable rather than guessed at.
struct PlayWidgetItemIntent: AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Play Item"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Item")
  var token: String

  init() {}

  init(token: String) {
    self.token = token
  }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.playWidgetItem(token: token)).throwIfUnavailable()
    return .result()
  }
}

/// The Play or Pause control's toggle. A control's toggle must be a `SetValueIntent`; this one is
/// also an `AudioPlaybackIntent`, so the system performs it in the app, where it starts or pauses
/// as Resume and Pause do. The control reads the toggle's current value from the widget snapshot,
/// the extension's only view of the player.
struct SetPlayingIntent: SetValueIntent, AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Play or Pause"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Playing")
  var value: Bool

  init() {}

  init(value: Bool) {
    self.value = value
  }

  static func action(playing: Bool) -> SiriPlaybackIntentAction {
    playing ? .resume : .pause
  }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(Self.action(playing: value)).throwIfUnavailable()
    return .result()
  }
}

/// A smart list widget row's play button. Like `PlayWidgetItemIntent` the token is opaque and
/// resolved by the app's token map, but a list row's entry also names its list, so the episode
/// starts that list's run, as Play on the list's screen does. A shelf row's token is refused.
struct PlaySmartListItemIntent: AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Play from Smart List"
  static let isDiscoverable = false
  nonisolated static var supportedModes: IntentModes { .background }
  nonisolated static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Episode")
  var token: String

  init() {}

  init(token: String) {
    self.token = token
  }

  func perform() async throws -> some IntentResult {
    try await SiriPlaybackIntentPerformer.perform(.playSmartListItem(token: token)).throwIfUnavailable()
    return .result()
  }
}

/// The smart list widget's configuration: which list it shows. `nil` until the listener picks one,
/// when the widget shows the first list.
struct SmartListWidgetIntent: WidgetConfigurationIntent {
  /// The widget's kind, here so the app can pick its configurations out of WidgetKit's.
  static let widgetKind = "com.remoteconcern.whirr.widget.smartList"
  static let title: LocalizedStringResource = "Smart List"
  static let description = IntentDescription("Choose the smart list this widget shows.")

  @Parameter(title: "List")
  var list: SmartListEntity?

  init() {}

  init(list: SmartListEntity?) {
    self.list = list
  }
}

/// A smart list as the widget picker offers it. The id is the list's device-local row id as
/// canonical decimal (`WidgetSmartListID`): stable across publications and account bindings, and
/// not a server identifier. Names come from the published list
/// file; nothing here opens the database, so the picker works in the extension.
struct SmartListEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Smart List"
  static let defaultQuery = SmartListEntityQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SmartListEntityQuery: EntityQuery {
  /// The App Group reader; a test passes one over a temporary container.
  var reader: WidgetSmartListsReader = .production

  init() {}

  init(reader: WidgetSmartListsReader) {
    self.reader = reader
  }

  func entities(for identifiers: [String]) async throws -> [SmartListEntity] {
    let lists = published
    return identifiers.compactMap { identifier in
      lists.first { $0.id == identifier }
    }
  }

  func suggestedEntities() async throws -> [SmartListEntity] {
    published
  }

  /// Display order; empty when signed out or nothing is published.
  var published: [SmartListEntity] {
    guard let file = reader.read(), file.accountStamp != nil else { return [] }
    return file.lists.map { SmartListEntity(id: WidgetSmartListID.string($0.id), name: $0.name) }
  }
}
