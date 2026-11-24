import AppIntents
import AppModel
import Foundation
import PlayerCore

/// Process-lifetime routing from App Intents into the current account graph. The handler is weak:
/// `RootComposition` owns the account-scoped `VoicePlaybackActions`, and replacing that
/// composition can never leave Siri retaining playback state from the previous account.
@MainActor
final class SiriPlaybackActionRouter {
  private weak var handler: (any VoicePlaybackActionHandling)?
  /// Starts a smart list's run, for the smart list widget's play button. Separate from the Core
  /// handler, whose `play(selection:)` starts no run (and ends one); nil where no smart lists are
  /// composed.
  private weak var smartLists: (any SmartListPlaybackStarting)?

  var isBound: Bool { handler != nil }

  func bind(
    _ handler: any VoicePlaybackActionHandling, smartLists: (any SmartListPlaybackStarting)? = nil
  ) {
    self.handler = handler
    self.smartLists = smartLists
  }

  func unbind() {
    handler = nil
    smartLists = nil
  }

  func resumeLastPlayed() async -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return await handler.resumeLastPlayed()
  }

  func pausePlayback() -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return handler.pausePlayback()
  }

  func skip(by seconds: Double) async -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return await handler.skip(by: seconds)
  }

  func setSleepTimer(_ duration: SleepTimerDuration) -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return handler.setSleepTimer(duration)
  }

  func play(selection: CompanionSelection) async -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return await handler.play(selection: selection)
  }

  /// Starts `selection` as part of the list's run, as Play on the list's own screen does; the run
  /// is recorded only once the start succeeded.
  func playFromList(listID: Int64, selection: CompanionSelection) async -> VoicePlaybackActionResult {
    guard handler != nil, let smartLists else { return .unavailable(.accountUnavailable) }
    guard let episodeID = selection.episodeID else { return .unavailable(.itemUnavailable) }
    let started = await smartLists.startFromList(
      listID: listID, itemID: selection.itemID, episodeID: episodeID)
    return started ? .performed : .unavailable(.startFailed)
  }

  func extendSleepTimer(by seconds: Double) -> VoicePlaybackActionResult {
    guard let handler else { return .unavailable(.accountUnavailable) }
    return handler.extendSleepTimer(by: seconds)
  }
}

/// Resolves the process router only after starting the process runtime: App Intents can be the
/// cold-launch entry point, before `RootView` exists, and reading `AppRuntime.shared.composition`
/// builds and binds the authenticated graph (or leaves the router unbound for setup or an
/// interrupted removal). These intents declare `supportedModes: .background`, so this may be all
/// that ever runs: no window and no scene phase. `noteHeadlessEntry` records that a scene-less
/// process is backgrounded, deferring to any scene that has reported.
@MainActor
enum SiriPlaybackIntentRuntime {
  static var router: SiriPlaybackActionRouter { router() }

  /// Before the first unlock since boot the store's files cannot open and there is no graph to
  /// compose. That intent gets an unbound router, so it fails as `.accountUnavailable` without
  /// composing anything, and a later intent bootstraps normally. Starting the runtime also runs
  /// the launch sequence, once per process, when no scene has.
  static func router(
    isDatabaseAvailable: @MainActor () -> Bool = { DatabaseHardware.sharedIfAvailable() != nil },
    bootstrap: @MainActor () -> Void = { AppRuntime.shared.start() }
  ) -> SiriPlaybackActionRouter {
    guard isDatabaseAvailable() else { return SiriPlaybackActionRouter() }
    bootstrap()
    let hardware = PlaybackHardware.shared
    hardware.noteHeadlessEntry()
    return hardware.siriPlaybackActionRouter
  }
}

/// The app's half of the intent split (`SiriPlaybackIntents.swift` holds the shared half): maps a
/// Core result onto the shared, payload-free response.
extension SiriPlaybackIntentResponse {
  static func make(
    for result: VoicePlaybackActionResult, success: SiriPlaybackIntentResponse
  ) -> SiriPlaybackIntentResponse {
    switch result {
    case .performed:
      return success
    case .unavailable(let reason):
      switch reason {
      case .accountUnavailable: return .accountUnavailable
      case .noBookmark: return .noBookmark
      case .noActivePlayback: return .noActivePlayback
      case .noChapters: return .noChapters
      case .startFailed: return .startFailed
      case .itemUnavailable: return .itemUnavailable
      case .noSleepTimer: return .noSleepTimer
      }
    }
  }
}

/// Reads the same independent device-local settings as the two in-app transport controls. The
/// value is resolved at execution time so changing Settings affects the next Siri request without
/// requiring a relaunch or App Shortcut refresh.
nonisolated enum SiriPlaybackSkipInterval {
  static func seconds(forward: Bool, defaults: UserDefaults = .standard) -> Double {
    let key =
      forward
      ? SkipIntervalConfiguration.forwardStorageKey
      : SkipIntervalConfiguration.backwardStorageKey
    let stored = defaults.integer(forKey: key)
    return Double(SkipIntervalConfiguration.resolvedSeconds(stored, forward: forward))
  }
}

extension SiriSleepTimerDuration {
  var playerDuration: SleepTimerDuration {
    switch self {
    case .off: .off
    case .fifteenMinutes: .fifteenMinutes
    case .thirtyMinutes: .thirtyMinutes
    case .fortyFiveMinutes: .fortyFiveMinutes
    case .sixtyMinutes: .sixtyMinutes
    case .endOfChapter: .endOfChapter
    }
  }
}

/// The app target's performer for the shared intents. The widget extension compiles its own,
/// which refuses: the system performs these intents in the app process.
@MainActor
enum SiriPlaybackIntentPerformer {
  static func perform(_ action: SiriPlaybackIntentAction) async -> SiriPlaybackIntentResponse {
    let response = await perform(action, router: SiriPlaybackIntentRuntime.router)
    switch action {
    case .setSleepTimer, .extendSleepTimer:
      // Inside a `LiveActivityIntent`'s `perform()` the app may start the activity from the
      // background, which the driver's own observation, running later, could not.
      PlaybackHardware.shared.sleepTimerActivity?.reconcile()
    case .resume, .pause, .skipForward, .skipBack, .playWidgetItem, .playSmartListItem:
      break
    }
    return response
  }

  /// Everything after resolving the process router, which is the one step a test cannot take
  /// without composing the real account graph.
  static func perform(
    _ action: SiriPlaybackIntentAction, router: SiriPlaybackActionRouter,
    defaults: UserDefaults = .standard,
    resolveWidgetToken: @MainActor (String) -> CompanionSelection? = { WidgetRuntime.shared.selection(for: $0) },
    resolveListToken: @MainActor (String) -> WidgetTokenMap.ListSelection? = {
      WidgetRuntime.shared.listSelection(for: $0)
    }
  ) async -> SiriPlaybackIntentResponse {
    switch action {
    case .resume:
      return .make(for: await router.resumeLastPlayed(), success: .resuming)
    case .pause:
      return .make(for: router.pausePlayback(), success: .paused)
    case .skipForward:
      let seconds = SiriPlaybackSkipInterval.seconds(forward: true, defaults: defaults)
      let result = await router.skip(by: seconds)
      return .make(for: result, success: .skippedForward)
    case .skipBack:
      let seconds = SiriPlaybackSkipInterval.seconds(forward: false, defaults: defaults)
      let result = await router.skip(by: -seconds)
      return .make(for: result, success: .skippedBack)
    case .setSleepTimer(let duration):
      return .make(
        for: router.setSleepTimer(duration.playerDuration), success: duration.successResponse)
    case .extendSleepTimer:
      let result = router.extendSleepTimer(by: ExtendSleepTimerIntent.extensionSeconds)
      return .make(for: result, success: .sleepTimerExtended)
    case .playWidgetItem(let token):
      guard let selection = resolveWidgetToken(token) else {
        return router.isBound ? .itemUnavailable : .accountUnavailable
      }
      return .make(for: await router.play(selection: selection), success: .resuming)
    case .playSmartListItem(let token):
      guard let row = resolveListToken(token) else {
        return router.isBound ? .itemUnavailable : .accountUnavailable
      }
      return .make(
        for: await router.playFromList(listID: row.listID, selection: row.selection), success: .resuming)
    }
  }
}

/// One provider, five stable App Shortcuts. Every phrase names the application, and the only
/// parameterized shortcut carries one finite AppEnum value.
///
/// Phrase order is load-bearing; naming the app does not win a phrase. The first phrase in each
/// array is the one Shortcuts and Siri advertise, so it must resolve to us. On device, "Resume
/// listening with Whirr" is shadowed by the system's media vocabulary and never reaches this
/// process, while "Continue listening in Whirr" always resolves, so it leads. The sleep timer
/// loses the same way on numeric durations, so phrasings avoiding the reserved words "sleep
/// timer" come first. Not unit-testable (`AppShortcut` hides its phrases): reordering needs a
/// device re-check.
struct WhirrAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ResumeListeningIntent(),
      phrases: [
        "Continue listening in \(.applicationName)",
        "Resume listening with \(.applicationName)",
      ],
      shortTitle: "Resume Listening",
      systemImageName: "play.fill")
    AppShortcut(
      intent: PausePlaybackIntent(),
      phrases: [
        "Pause playback in \(.applicationName)",
        "Pause \(.applicationName)",
      ],
      shortTitle: "Pause Playback",
      systemImageName: "pause.fill")
    AppShortcut(
      intent: SkipForwardIntent(),
      phrases: [
        "Skip forward in \(.applicationName)",
        "Jump forward in \(.applicationName)",
      ],
      shortTitle: "Skip Forward",
      systemImageName: "goforward")
    AppShortcut(
      intent: SkipBackIntent(),
      phrases: [
        "Skip back in \(.applicationName)",
        "Rewind in \(.applicationName)",
      ],
      shortTitle: "Skip Back",
      systemImageName: "gobackward")
    AppShortcut(
      intent: SetSleepTimerIntent(),
      phrases: [
        "Set the \(.applicationName) timer to \(\.$duration)",
        "Change the \(.applicationName) timer to \(\.$duration)",
        "Set the sleep timer in \(.applicationName) to \(\.$duration)",
        "Change the sleep timer in \(.applicationName) to \(\.$duration)",
      ],
      shortTitle: "Set Sleep Timer",
      systemImageName: "moon.zzz")
  }
}
