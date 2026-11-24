import AppIntents
import AppModel
import Foundation
import Persistence
import PlayerCore
import Testing

@testable import Whirr

@MainActor
@Suite("Siri playback actions", .serialized)
struct SiriPlaybackActionsTests {

  @Test("the weak router forwards every action and preserves the Core result")
  func routerForwardsEveryAction() async throws {
    let router = SiriPlaybackActionRouter()
    let handler = FakeVoicePlaybackActionHandler()
    handler.resumeResult = .unavailable(.noBookmark)
    handler.pauseResult = .performed
    handler.skipResult = .unavailable(.startFailed)
    handler.sleepTimerResult = .unavailable(.noActivePlayback)
    handler.playResult = .unavailable(.itemUnavailable)
    handler.extendResult = .unavailable(.noSleepTimer)
    router.bind(handler)
    let selection = CompanionSelection(source: try #require(PodcastSourceIdentity.abs(itemId: "item")))

    #expect(await router.resumeLastPlayed() == .unavailable(.noBookmark))
    #expect(router.pausePlayback() == .performed)
    #expect(await router.skip(by: -45) == .unavailable(.startFailed))
    #expect(
      router.setSleepTimer(.endOfChapter)
        == .unavailable(.noActivePlayback))
    #expect(await router.play(selection: selection) == .unavailable(.itemUnavailable))
    #expect(router.extendSleepTimer(by: 900) == .unavailable(.noSleepTimer))
    #expect(
      handler.calls == [
        .resume, .pause, .skip(-45), .sleepTimer(.endOfChapter), .play(selection), .extend(900),
      ])
  }

  /// Each shared intent hands the performer one action; this pins which handler method that action
  /// reaches, with what argument, and which response a success becomes. Only resolving the process
  /// router is left to `perform(_:)`.
  @Test("every intent action reaches its own handler method and success response")
  func performerRoutesEveryAction() async throws {
    let router = SiriPlaybackActionRouter()
    let handler = FakeVoicePlaybackActionHandler()
    router.bind(handler)
    let suite = "SiriPlaybackActionsTests.performer-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Non-default presets, so a performer ignoring the setting would be caught.
    defaults.set(75, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set(45, forKey: SkipIntervalConfiguration.backwardStorageKey)

    let cases: [(SiriPlaybackIntentAction, FakeVoicePlaybackActionHandler.Call, SiriPlaybackIntentResponse)] = [
      (.resume, .resume, .resuming),
      (.pause, .pause, .paused),
      (.skipForward, .skip(75), .skippedForward),
      (.skipBack, .skip(-45), .skippedBack),
      (.setSleepTimer(.fifteenMinutes), .sleepTimer(.fifteenMinutes), .sleepTimerSet(.fifteenMinutes)),
      (.setSleepTimer(.endOfChapter), .sleepTimer(.endOfChapter), .sleepTimerSet(.endOfChapter)),
      (.setSleepTimer(.off), .sleepTimer(.off), .sleepTimerCancelled),
      (.extendSleepTimer, .extend(ExtendSleepTimerIntent.extensionSeconds), .sleepTimerExtended),
    ]
    for (action, call, success) in cases {
      let response = await SiriPlaybackIntentPerformer.perform(
        action, router: router, defaults: defaults)
      #expect(response == success, "\(action)")
      #expect(handler.calls.last == call, "\(action)")
    }
    #expect(handler.calls.count == cases.count)

    router.unbind()
    #expect(
      await SiriPlaybackIntentPerformer.perform(.extendSleepTimer, router: router, defaults: defaults)
        == .accountUnavailable)
  }

  @Test("a widget token resolves only through a bound runtime's own account")
  func performerRefusesAnUnresolvedToken() async throws {
    let router = SiriPlaybackActionRouter()
    let handler = FakeVoicePlaybackActionHandler()
    let suite = "WidgetPublicationTests.performer-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let selection = CompanionSelection(source: try #require(PodcastSourceIdentity(itemId: "book-a")))

    #expect(
      await SiriPlaybackIntentPerformer.perform(
        .playWidgetItem(token: "t"), router: router, defaults: defaults,
        resolveWidgetToken: { _ in nil }) == .accountUnavailable)

    router.bind(handler)
    #expect(
      await SiriPlaybackIntentPerformer.perform(
        .playWidgetItem(token: "t"), router: router, defaults: defaults,
        resolveWidgetToken: { _ in nil }) == .itemUnavailable)
    #expect(handler.calls.isEmpty)

    #expect(
      await SiriPlaybackIntentPerformer.perform(
        .playWidgetItem(token: "t"), router: router, defaults: defaults,
        resolveWidgetToken: { $0 == "t" ? selection : nil }) == .resuming)
    #expect(handler.calls == [.play(selection)])
  }

  @Test("the play intent is a hidden, lock-screen-safe audio intent carrying only the token")
  func playIntentShape() {
    #expect(PlayWidgetItemIntent.isDiscoverable == false)
    #expect(PlayWidgetItemIntent.supportedModes == .background)
    #expect(PlayWidgetItemIntent.authenticationPolicy == .alwaysAllowed)
    #expect(PlayWidgetItemIntent(token: "abc").token == "abc")
  }

  /// The Play or Pause control's toggle: turning it on resumes, off pauses, with the same reasons
  /// and spoken copy as the Resume and Pause intents.
  @Test("the play-or-pause toggle is a hidden, lock-screen-safe audio intent over resume and pause")
  func playingToggleShape() {
    #expect(SetPlayingIntent.isDiscoverable == false)
    #expect(SetPlayingIntent.supportedModes == .background)
    #expect(SetPlayingIntent.authenticationPolicy == .alwaysAllowed)
    #expect(SetPlayingIntent(value: true).value)
    #expect(SetPlayingIntent.action(playing: true) == .resume)
    #expect(SetPlayingIntent.action(playing: false) == .pause)
  }

  /// The Live Activity's buttons and the Sleep control may start, extend or end the activity from
  /// the background, so they are `LiveActivityIntent`s; they are not Siri vocabulary, so none is
  /// discoverable or has a persistent identifier to keep stable.
  @Test("the activity and control intents are hidden, lock-screen-safe Live Activity intents")
  func liveActivityIntentsAreHiddenAndLockScreenSafe() {
    Self.requireLiveActivityIntent(StartSleepTimerIntent.self)
    Self.requireLiveActivityIntent(ExtendSleepTimerIntent.self)
    Self.requireLiveActivityIntent(CancelSleepTimerIntent.self)
    #expect(StartSleepTimerIntent.isDiscoverable == false)
    #expect(ExtendSleepTimerIntent.isDiscoverable == false)
    #expect(CancelSleepTimerIntent.isDiscoverable == false)
    #expect(StartSleepTimerIntent.supportedModes == .background)
    #expect(ExtendSleepTimerIntent.supportedModes == .background)
    #expect(CancelSleepTimerIntent.supportedModes == .background)
    #expect(StartSleepTimerIntent.authenticationPolicy == .alwaysAllowed)
    #expect(ExtendSleepTimerIntent.authenticationPolicy == .alwaysAllowed)
    #expect(CancelSleepTimerIntent.authenticationPolicy == .alwaysAllowed)
    #expect(StartSleepTimerIntent(duration: .fortyFiveMinutes).duration == .fortyFiveMinutes)
  }

  @Test("an unbound or released account handler is unavailable without being retained")
  func routerDoesNotRetainAccountHandler() async {
    let router = SiriPlaybackActionRouter()

    #expect(await router.resumeLastPlayed() == .unavailable(.accountUnavailable))
    #expect(router.pausePlayback() == .unavailable(.accountUnavailable))
    #expect(await router.skip(by: 30) == .unavailable(.accountUnavailable))
    #expect(
      router.setSleepTimer(.thirtyMinutes)
        == .unavailable(.accountUnavailable))

    weak var releasedHandler: FakeVoicePlaybackActionHandler?
    do {
      let handler = FakeVoicePlaybackActionHandler()
      releasedHandler = handler
      router.bind(handler)
      #expect(router.isBound)
    }

    #expect(releasedHandler == nil)
    #expect(router.isBound == false)
    #expect(router.pausePlayback() == .unavailable(.accountUnavailable))
  }

  @Test("runtime composition binds one retained handler and setup composition unbinds it")
  func rootCompositionOwnsTheCurrentAccountHandler() throws {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let authenticatedDatabase = try AppDatabase.inMemory()
    _ = try AccountDAO(database: authenticatedDatabase).save(
      AccountRecord(
        clientUUID: "siri-actions",
        serverBaseURL: "https://siri-actions.invalid",
        serverUserId: "siri-actions-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "siri-actions-library"))

    let runtime = RootComposition(
      hardware: hardware,
      mode: .runtime,
      database: authenticatedDatabase,
      applicationSupportDirectory: Self.temporaryDirectory(), watchCompanionRuntime: nil)

    #expect(runtime.voicePlaybackActions != nil)
    #expect(hardware.siriPlaybackActionRouter.isBound)
    #expect(hardware.isNowPlayingMetadataBound)

    let setup = RootComposition(
      hardware: hardware,
      mode: .automatic,
      database: try AppDatabase.inMemory(),
      applicationSupportDirectory: Self.temporaryDirectory(), watchCompanionRuntime: nil)

    #expect(setup.environment.composition == .setup)
    #expect(setup.voicePlaybackActions == nil)
    #expect(hardware.siriPlaybackActionRouter.isBound == false)
    _ = runtime
  }

  @Test("logout immediately removes the process-wide Siri route")
  func logoutUnbindsRouter() {
    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let handler = FakeVoicePlaybackActionHandler()
    hardware.siriPlaybackActionRouter.bind(handler)

    hardware.prepareForLogout()

    #expect(hardware.siriPlaybackActionRouter.isBound == false)
  }

  @Test("skip intents read the current directional playback preferences")
  func skipIntervalsReusePlaybackPreferences() throws {
    let suiteName = "SiriPlaybackActionsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(75, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set(10, forKey: SkipIntervalConfiguration.backwardStorageKey)

    #expect(SiriPlaybackSkipInterval.seconds(forward: true, defaults: defaults) == 75)
    #expect(SiriPlaybackSkipInterval.seconds(forward: false, defaults: defaults) == 10)

    defaults.set(-1, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set(1_000, forKey: SkipIntervalConfiguration.backwardStorageKey)
    #expect(
      SiriPlaybackSkipInterval.seconds(forward: true, defaults: defaults)
        == Double(SkipIntervalConfiguration.defaultForwardSeconds))
    #expect(
      SiriPlaybackSkipInterval.seconds(forward: false, defaults: defaults)
        == Double(SkipIntervalConfiguration.defaultBackwardSeconds))
  }

  @Test("the sleep timer exposes only the six finite choices and maps them exactly")
  func sleepTimerChoicesAreFinite() {
    #expect(
      SiriSleepTimerDuration.allCases == [
        .off, .fifteenMinutes, .thirtyMinutes, .fortyFiveMinutes, .sixtyMinutes,
        .endOfChapter,
      ])
    #expect(SiriSleepTimerDuration.off.playerDuration == .off)
    #expect(SiriSleepTimerDuration.fifteenMinutes.playerDuration == .fifteenMinutes)
    #expect(SiriSleepTimerDuration.thirtyMinutes.playerDuration == .thirtyMinutes)
    #expect(SiriSleepTimerDuration.fortyFiveMinutes.playerDuration == .fortyFiveMinutes)
    #expect(SiriSleepTimerDuration.sixtyMinutes.playerDuration == .sixtyMinutes)
    #expect(SiriSleepTimerDuration.endOfChapter.playerDuration == .endOfChapter)
  }

  @Test("the merged bookmark route exposes an RSS identity for a cold voice resume")
  func coldRSSResumeUsesMergedBookmarkIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/siri.xml", title: "Siri Show",
        author: "Siri Host", subscribedAt: Date())
      try feed.insert(db)
      let id = try #require(feed.id)
      var episode = RSSEpisodeRecord(
        feedId: id, identityKey: "episode-1", title: "Siri Episode",
        enclosureURL: "https://cdn.example.test/siri.mp3", lastSeenGeneration: 1)
      try episode.insert(db)
      return id
    }
    let rss = RSSPlaybackBookmarkStore(database: database)
    try await rss.setBookmark(feedId: feedID, episodeID: "episode-1")
    let route = RoutingPlaybackBookmarkStoring(
      abs: NoOpPlaybackBookmarkStoring(), rss: rss,
      reads: MergedPlaybackBookmarkReading(database: database))

    let bookmark = try #require(await route.fetchBookmark())

    let expectedItemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    #expect(bookmark.serverItemId == expectedItemID)
    #expect(bookmark.episodeID == "episode-1")
    #expect(bookmark.title == "Siri Episode")
  }

  @Test("an intent before first unlock skips the launch composition and is unavailable")
  func intentBeforeFirstUnlockDoesNotBootstrap() async {
    var bootstrapCount = 0
    let router = SiriPlaybackIntentRuntime.router(
      isDatabaseAvailable: { false }, bootstrap: { bootstrapCount += 1 })

    #expect(bootstrapCount == 0)
    #expect(router !== PlaybackHardware.shared.siriPlaybackActionRouter)
    #expect(router.isBound == false)
    #expect(await router.resumeLastPlayed() == .unavailable(.accountUnavailable))
    #expect(router.pausePlayback() == .unavailable(.accountUnavailable))
  }

  @Test("an intent with the database available bootstraps and uses the process router")
  func intentWithDatabaseBootstraps() {
    var bootstrapCount = 0
    let router = SiriPlaybackIntentRuntime.router(
      isDatabaseAvailable: { true }, bootstrap: { bootstrapCount += 1 })

    #expect(bootstrapCount == 1)
    #expect(router === PlaybackHardware.shared.siriPlaybackActionRouter)
  }

  @Test("the sleep timer intent reports an unavailable action as a failure")
  func sleepTimerIntentPropagatesUnavailableResult() async {
    let router = SiriPlaybackIntentRuntime.router
    let productionHandler = AppRuntime.shared.composition.voicePlaybackActions
    let handler = FakeVoicePlaybackActionHandler()
    handler.sleepTimerResult = .unavailable(.noActivePlayback)
    router.bind(handler)
    defer {
      if let productionHandler {
        router.bind(productionHandler)
      } else {
        router.unbind()
      }
    }

    let intent = SetSleepTimerIntent()
    intent.duration = .thirtyMinutes

    await #expect(throws: (any Error).self) {
      _ = try await intent.perform()
    }
    #expect(handler.calls == [.sleepTimer(.thirtyMinutes)])
  }

  @Test("five stable background audio shortcuts use the lock-screen-safe policy")
  func shortcutMetadataIsStable() {
    #expect(WhirrAppShortcuts.appShortcuts.count == 5)
    // Shortcuts namespaces `persistentIdentifier` with the bundle ID when it resolves an action.
    // A value that repeats the bundle ID is looked up doubled
    // ("com.remoteconcern.whirr.com.remoteconcern.whirr.pause-playback"), resolves to a
    // WFMissingAction, and every shortcut fails with "an action could not be found".
    let identifiers = [
      ResumeListeningIntent.persistentIdentifier,
      PausePlaybackIntent.persistentIdentifier,
      SkipForwardIntent.persistentIdentifier,
      SkipBackIntent.persistentIdentifier,
      SetSleepTimerIntent.persistentIdentifier,
    ]
    for identifier in identifiers {
      #expect(identifier.contains("com.remoteconcern.whirr") == false)
    }
    #expect(ResumeListeningIntent.persistentIdentifier == "resume-listening")
    #expect(PausePlaybackIntent.persistentIdentifier == "pause-playback")
    #expect(SkipForwardIntent.persistentIdentifier == "skip-forward")
    #expect(SkipBackIntent.persistentIdentifier == "skip-back")
    #expect(SetSleepTimerIntent.persistentIdentifier == "set-sleep-timer")
    #expect(ResumeListeningIntent.title.key == "Resume Listening")
    #expect(PausePlaybackIntent.title.key == "Pause Playback")
    #expect(SkipForwardIntent.title.key == "Skip Forward")
    #expect(SkipBackIntent.title.key == "Skip Back")
    #expect(SetSleepTimerIntent.title.key == "Set Sleep Timer")

    Self.requireAudioPlaybackIntent(ResumeListeningIntent.self)
    Self.requireAudioPlaybackIntent(PausePlaybackIntent.self)
    Self.requireAudioPlaybackIntent(SkipForwardIntent.self)
    Self.requireAudioPlaybackIntent(SkipBackIntent.self)
    Self.requireAudioPlaybackIntent(SetSleepTimerIntent.self)

    #expect(ResumeListeningIntent.supportedModes == .background)
    #expect(PausePlaybackIntent.supportedModes == .background)
    #expect(SkipForwardIntent.supportedModes == .background)
    #expect(SkipBackIntent.supportedModes == .background)
    #expect(SetSleepTimerIntent.supportedModes == .background)
    #expect(ResumeListeningIntent.authenticationPolicy == .alwaysAllowed)
    #expect(PausePlaybackIntent.authenticationPolicy == .alwaysAllowed)
    #expect(SkipForwardIntent.authenticationPolicy == .alwaysAllowed)
    #expect(SkipBackIntent.authenticationPolicy == .alwaysAllowed)
    #expect(SetSleepTimerIntent.authenticationPolicy == .alwaysAllowed)
  }

  @Test("Core unavailability reasons map to concise generic responses")
  func responseMappingDisclosesNoPlaybackMetadata() {
    #expect(
      SiriPlaybackIntentResponse.make(for: .performed, success: .resuming)
        == .resuming)
    #expect(
      SiriPlaybackIntentResponse.make(
        for: .unavailable(.accountUnavailable), success: .resuming)
        == .accountUnavailable)
    #expect(
      SiriPlaybackIntentResponse.make(for: .unavailable(.noBookmark), success: .resuming)
        == .noBookmark)
    #expect(
      SiriPlaybackIntentResponse.make(
        for: .unavailable(.noActivePlayback), success: .paused)
        == .noActivePlayback)
    #expect(
      SiriPlaybackIntentResponse.make(
        for: .unavailable(.noChapters), success: .sleepTimerSet(.endOfChapter))
        == .noChapters)
    #expect(
      SiriPlaybackIntentResponse.make(for: .unavailable(.startFailed), success: .resuming)
        == .startFailed)
    #expect(
      SiriPlaybackIntentResponse.accountUnavailable.localizedStringResource.key
        == "Sign in to Whirr, then try again.")
    #expect(
      SiriPlaybackIntentResponse.startFailed.localizedStringResource.key
        == "Playback couldn’t start. Check your connection and try again.")
    #expect(
      SiriPlaybackIntentResponse.noChapters.localizedStringResource.key
        == "The current item has no chapters.")
  }

  @Test("unavailable actions throw App Intents localized resources")
  func unavailableResponsesThrowLocalizedIntentErrors() {
    do {
      try SiriPlaybackIntentResponse.noBookmark.throwIfUnavailable()
      Issue.record("Expected the unavailable response to throw")
    } catch {
      let localizedError = error as? any CustomLocalizedStringResourceConvertible
      #expect(localizedError?.localizedStringResource.key == "There’s no recent playback yet.")
    }
  }

  @Test("every sleep timer choice has a value-specific generic confirmation")
  func sleepTimerConfirmationsIncludeTheSelectedDuration() {
    #expect(
      SiriPlaybackIntentResponse.sleepTimerCancelled.localizedStringResource.key
        == "Sleep timer cancelled.")
    #expect(
      SiriPlaybackIntentResponse.sleepTimerSet(.fifteenMinutes).localizedStringResource.key
        == "Sleep timer set for 15 minutes.")
    #expect(
      SiriPlaybackIntentResponse.sleepTimerSet(.thirtyMinutes).localizedStringResource.key
        == "Sleep timer set for 30 minutes.")
    #expect(
      SiriPlaybackIntentResponse.sleepTimerSet(.fortyFiveMinutes).localizedStringResource.key
        == "Sleep timer set for 45 minutes.")
    #expect(
      SiriPlaybackIntentResponse.sleepTimerSet(.sixtyMinutes).localizedStringResource.key
        == "Sleep timer set for 60 minutes.")
    #expect(
      SiriPlaybackIntentResponse.sleepTimerSet(.endOfChapter).localizedStringResource.key
        == "Playback will stop at the end of the chapter.")
  }

  private static func requireAudioPlaybackIntent<Intent: AudioPlaybackIntent>(_: Intent.Type) {}

  private static func requireLiveActivityIntent<Intent: LiveActivityIntent>(_: Intent.Type) {}

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-siri-actions-\(UUID().uuidString)", isDirectory: true)
  }
}

@MainActor
private final class FakeVoicePlaybackActionHandler: VoicePlaybackActionHandling {
  enum Call: Equatable {
    case resume
    case pause
    case skip(Double)
    case sleepTimer(SleepTimerDuration)
    case play(CompanionSelection)
    case extend(Double)
  }

  var resumeResult: VoicePlaybackActionResult = .performed
  var pauseResult: VoicePlaybackActionResult = .performed
  var skipResult: VoicePlaybackActionResult = .performed
  var sleepTimerResult: VoicePlaybackActionResult = .performed
  var playResult: VoicePlaybackActionResult = .performed
  var extendResult: VoicePlaybackActionResult = .performed
  private(set) var calls: [Call] = []

  func resumeLastPlayed() async -> VoicePlaybackActionResult {
    calls.append(.resume)
    return resumeResult
  }

  func pausePlayback() -> VoicePlaybackActionResult {
    calls.append(.pause)
    return pauseResult
  }

  func skip(by seconds: Double) async -> VoicePlaybackActionResult {
    calls.append(.skip(seconds))
    return skipResult
  }

  func setSleepTimer(_ duration: SleepTimerDuration) -> VoicePlaybackActionResult {
    calls.append(.sleepTimer(duration))
    return sleepTimerResult
  }

  func play(selection: CompanionSelection) async -> VoicePlaybackActionResult {
    calls.append(.play(selection))
    return playResult
  }

  func extendSleepTimer(by seconds: Double) -> VoicePlaybackActionResult {
    calls.append(.extend(seconds))
    return extendResult
  }
}
