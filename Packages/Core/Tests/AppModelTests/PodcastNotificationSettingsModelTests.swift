import AppModel
import Persistence
import SyncEngine
import TestSupport
import Testing

@Suite("Podcast notification settings", .timeLimit(.minutes(1)))
struct PodcastNotificationSettingsModelTests {
  @Test("durable preference defaults off and round-trips")
  func preference() async {
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    let preference = PodcastNotificationPreference(defaults: defaults)
    #expect(await preference.isNewEpisodeNotificationEnabled() == false)
    await preference.setNewEpisodeNotificationEnabled(true)
    #expect(defaults.values[PodcastNotificationPreference.storageKey] == true)
    #expect(
      await PodcastNotificationPreference(defaults: defaults)
        .isNewEpisodeNotificationEnabled())
  }

  @MainActor
  @Test("loading never requests permission and absent intent is off")
  func silentLoad() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(status: .notDetermined)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.load()
    #expect(model.isEnabled == false)
    #expect(model.authorizationStatus == .notDetermined)
    #expect(await authorizer.requestCount == 0)
  }

  @MainActor
  @Test("explicit enable requests once and stays off when the prompt is denied")
  func explicitEnable() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(status: .notDetermined, requestResult: .denied)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled == false)
    #expect(model.authorizationStatus == .denied)
    #expect(preference.enabled == false)
    #expect(await authorizer.requestCount == 1)
    // The listener has just answered the system prompt; a second explanation would nag.
    #expect(model.enableRefusal == nil)
  }

  @MainActor
  @Test("explicit enable that the prompt allows turns on")
  func explicitEnableAllowed() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(status: .notDetermined, requestResult: .allowed)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled)
    #expect(preference.enabled)
    #expect(model.enableRefusal == nil)
  }

  @MainActor
  @Test("enable is refused with an explanation when notifications are already denied")
  func enableRefusedWhenNotificationsDenied() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(status: .denied)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled == false)
    #expect(preference.enabled == false)
    #expect(model.enableRefusal == .notificationsDenied)
    #expect(model.requiresSystemSettingsRecovery)
  }

  @MainActor
  @Test("enable is refused before the notification prompt when Background App Refresh is off")
  func enableRefusedWhenBackgroundRefreshDenied() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(
      status: .notDetermined, backgroundRefresh: .denied)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled == false)
    #expect(preference.enabled == false)
    #expect(await authorizer.requestCount == 0)
    #expect(model.enableRefusal == .backgroundRefreshDenied)
    #expect(model.requiresSystemSettingsRecovery)
  }

  @MainActor
  @Test("a restricted Background App Refresh refuses without offering Settings")
  func enableRefusedWhenBackgroundRefreshRestricted() async {
    let authorizer = NotificationAuthorizerFake(status: .allowed, backgroundRefresh: .restricted)
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false), authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled == false)
    #expect(model.enableRefusal == .backgroundRefreshRestricted)
    #expect(model.requiresSystemSettingsRecovery == false)
  }

  @MainActor
  @Test("Low Power Mode is temporary, so it pauses checks without refusing enable")
  func lowPowerModeDoesNotRefuse() async {
    let authorizer = NotificationAuthorizerFake(
      status: .allowed, backgroundRefresh: .pausedByLowPowerMode)
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false), authorizer: authorizer)
    await model.setEnabled(true)
    #expect(model.isEnabled)
    #expect(model.enableRefusal == nil)
    #expect(model.backgroundRefreshWarning == SettingsCopy.backgroundRefreshPausedWarning)
  }

  @MainActor
  @Test("dismissing the refusal clears it")
  func dismissRefusal() async {
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false),
      authorizer: NotificationAuthorizerFake(status: .denied))
    await model.setEnabled(true)
    model.dismissEnableRefusal()
    #expect(model.enableRefusal == nil)
  }

  @MainActor
  @Test("a permission revoked after enabling keeps the intent and warns")
  func revokedAfterEnableKeepsIntent() async {
    let preference = FakeRSSNotificationIntentReading(enabled: true)
    let authorizer = NotificationAuthorizerFake(status: .allowed)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)
    await model.load()
    #expect(model.backgroundRefreshWarning == nil)

    await authorizer.setBackgroundRefresh(.denied)
    await model.sceneDidBecomeActive().value

    #expect(model.isEnabled)
    #expect(preference.enabled)
    #expect(model.backgroundRefreshStatus == .denied)
    #expect(model.backgroundRefreshWarning == SettingsCopy.backgroundRefreshOffWarning)
    #expect(model.showsSystemSettingsRecovery)

    await authorizer.setBackgroundRefresh(.restricted)
    await model.sceneDidBecomeActive().value
    #expect(model.backgroundRefreshWarning == SettingsCopy.backgroundRefreshRestrictedWarning)
    #expect(model.showsSystemSettingsRecovery == false)
  }

  @MainActor
  @Test("an off toggle carries no Background App Refresh warning")
  func noWarningWhenOff() async {
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false),
      authorizer: NotificationAuthorizerFake(status: .allowed, backgroundRefresh: .denied))
    await model.load()
    #expect(model.backgroundRefreshWarning == nil)
    #expect(model.showsSystemSettingsRecovery == false)
  }

  @MainActor
  @Test("a denied explicit feed enable is refused without changing the global intent")
  func explicitFeedEnableRecovery() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    let authorizer = NotificationAuthorizerFake(status: .notDetermined, requestResult: .denied)
    let model = PodcastNotificationSettingsModel(preference: preference, authorizer: authorizer)

    let authorization = await model.authorizeExplicitFeedEnableIfNeeded()

    #expect(authorization == .declined)
    #expect(model.isEnabled == false)
    #expect(preference.enabled == false)
    #expect(model.authorizationStatus == .denied)
    #expect(model.requiresSystemSettingsRecovery)
    #expect(model.showsSystemSettingsRecovery == false)
    #expect(model.enableRefusal == nil)
  }

  @MainActor
  @Test("an explicit feed enable follows the same refusal rules as the global toggle")
  func explicitFeedEnableRefusals() async {
    let authorizer = NotificationAuthorizerFake(status: .allowed, backgroundRefresh: .denied)
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false), authorizer: authorizer)
    #expect(
      await model.authorizeExplicitFeedEnableIfNeeded() == .refused(.backgroundRefreshDenied))
    // Returned to the asking screen, not published for the global toggle's alert.
    #expect(model.enableRefusal == nil)
    #expect(model.requiresSystemSettingsRecovery)

    await authorizer.setBackgroundRefresh(.available)
    #expect(await model.authorizeExplicitFeedEnableIfNeeded() == .permitted)
  }

  @MainActor
  @Test("already denied does not prompt again")
  func deniedDoesNotReprompt() async {
    let authorizer = NotificationAuthorizerFake(status: .denied)
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false), authorizer: authorizer)
    await model.setEnabled(true)
    #expect(await authorizer.requestCount == 0)
  }

  @MainActor
  @Test("turning global intent off disarms without changing authorization")
  func disableDisarms() async {
    let lifecycle = FakeRSSNotificationLifecycleHandling()
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: true),
      authorizer: NotificationAuthorizerFake(status: .allowed), lifecycle: lifecycle)
    await model.setEnabled(false)
    #expect(await lifecycle.feedIDs == [nil])
    #expect(model.authorizationStatus == .allowed)
  }

  @MainActor
  @Test("returning active refreshes authorization without prompting")
  func sceneActiveRefreshesAuthorization() async {
    let authorizer = NotificationAuthorizerFake(status: .denied)
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: true), authorizer: authorizer)
    await model.load()
    #expect(model.authorizationStatus == .denied)

    await authorizer.setStatus(.allowed)
    await model.sceneDidBecomeActive().value

    #expect(model.authorizationStatus == .allowed)
    #expect(await authorizer.requestCount == 0)
  }

  @MainActor
  @Test("rapid global changes persist and publish in invocation order")
  func rapidGlobalChangesStayOrdered() async {
    let preference = FakeRSSNotificationIntentReading(enabled: false)
    preference.writeGate.hold()
    let model = PodcastNotificationSettingsModel(
      preference: preference, authorizer: NotificationAuthorizerFake(status: .allowed))

    let enable = model.requestEnabled(true)
    await preference.writeGate.waitUntilParked()
    let disable = model.requestEnabled(false)
    await Task.yield()
    #expect(preference.writes == [true])

    preference.writeGate.releaseNext()
    await preference.writeGate.waitUntilParked()
    preference.writeGate.releaseNext()
    await enable.value
    await disable.value

    #expect(preference.writes == [true, false])
    #expect(preference.enabled == false)
    #expect(model.isEnabled == false)
  }

  @MainActor
  @Test("the model reports loaded once the stored intent has been published")
  func loadMarksLoaded() async {
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: true),
      authorizer: NotificationAuthorizerFake(status: .allowed))
    #expect(model.hasLoaded == false)
    await model.load()
    #expect(model.hasLoaded)
    #expect(model.isEnabled)
  }

  @MainActor
  @Test("a load overtaken by the scene refresh publishes nothing and stays unloaded")
  func overtakenLoadStaysUnloaded() async {
    let preference = FakeRSSNotificationIntentReading(enabled: true)
    preference.readGate.hold()
    let model = PodcastNotificationSettingsModel(
      preference: preference, authorizer: NotificationAuthorizerFake(status: .allowed))

    let loading = Task { @MainActor in await model.load() }
    await preference.readGate.waitUntilParked()
    let refresh = model.sceneDidBecomeActive()
    preference.readGate.release()
    await loading.value
    await refresh.value

    #expect(model.hasLoaded == false)
    #expect(model.isEnabled == false)

    await model.load()
    #expect(model.hasLoaded)
    #expect(model.isEnabled)
  }

  @MainActor
  @Test("an explicit toggle also counts as loaded")
  func toggleMarksLoaded() async {
    let model = PodcastNotificationSettingsModel(
      preference: FakeRSSNotificationIntentReading(enabled: false),
      authorizer: NotificationAuthorizerFake(status: .allowed))
    await model.setEnabled(true)
    #expect(model.hasLoaded)
  }
}

private actor NotificationAuthorizerFake: RSSLocalNotificationAuthorizing {
  var status: RSSLocalNotificationAuthorizationStatus
  var backgroundRefresh: BackgroundRefreshStatus
  let requestResult: RSSLocalNotificationAuthorizationStatus
  var requestCount = 0
  init(
    status: RSSLocalNotificationAuthorizationStatus,
    requestResult: RSSLocalNotificationAuthorizationStatus = .allowed,
    backgroundRefresh: BackgroundRefreshStatus = .available
  ) {
    self.status = status
    self.requestResult = requestResult
    self.backgroundRefresh = backgroundRefresh
  }
  func authorizationStatus() async -> RSSLocalNotificationAuthorizationStatus { status }
  func requestAuthorization() async -> RSSLocalNotificationAuthorizationStatus {
    requestCount += 1
    status = requestResult
    return status
  }
  func backgroundRefreshStatus() async -> BackgroundRefreshStatus { backgroundRefresh }

  func setStatus(_ status: RSSLocalNotificationAuthorizationStatus) {
    self.status = status
  }

  func setBackgroundRefresh(_ status: BackgroundRefreshStatus) {
    backgroundRefresh = status
  }
}
