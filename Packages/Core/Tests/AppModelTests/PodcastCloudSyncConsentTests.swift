import Foundation
import Testing

@testable import AppModel

@Suite struct PodcastCloudSyncConsentStoreTests {
  @Test func freshInstallHasNoConsent() {
    let store = PodcastCloudSyncConsentStore(defaults: MemoryConsentDefaults(), identity: FixedIdentity("a"))
    #expect(store.hasConsent() == false)
    #expect(PodcastCloudSyncGate(consent: store, destinationReady: true).allowsCloudWork == false)
  }

  @Test func grantPersistsBoundToTheInstallTokenAndSurvivesRelaunch() {
    let defaults = MemoryConsentDefaults()
    let first = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a"))
    #expect(first.grant())
    #expect(first.hasConsent())
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == "a")

    let relaunched = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a"))
    #expect(relaunched.hasConsent())
  }

  @Test func restoredDefaultsOnAnotherInstallReadAsNoConsentAndClearTheFlag() {
    let defaults = MemoryConsentDefaults()
    PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a")).grant()

    let migrated = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("b"))
    #expect(migrated.hasConsent() == false)
    #expect(defaults.boolValue(forKey: PodcastCloudSyncConsentStore.consentKey) == false)
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == nil)

    // Returning to the original identity cannot revive the cleared flag.
    #expect(PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a")).hasConsent() == false)
  }

  @Test func absentInstallIdentityCannotGrantOrHonourConsent() {
    let defaults = MemoryConsentDefaults()
    defaults.setBoolValue(true, forKey: PodcastCloudSyncConsentStore.consentKey)
    defaults.setStringValue("a", forKey: PodcastCloudSyncConsentStore.installTokenKey)
    let store = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity(nil))
    #expect(store.hasConsent() == false)
    #expect(store.grant() == false)
    #expect(defaults.boolValue(forKey: PodcastCloudSyncConsentStore.consentKey) == false)
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == nil)
  }

  /// Before first unlock the identity cannot be read at all. That is not evidence of another
  /// installation, so the stored consent must survive for the read that follows the unlock.
  @Test func unreadableInstallIdentityReadsAsNoConsentAndLeavesStoredConsentIntact() async {
    let defaults = MemoryConsentDefaults()
    PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a")).grant()

    let locked = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity(.unreadable))
    #expect(locked.hasConsent() == false)
    var iterator = locked.observeConsent().makeAsyncIterator()
    #expect(await iterator.next() == false)
    #expect(locked.grant() == false)
    #expect(PodcastCloudSyncGate(consent: locked, destinationReady: true).allowsCloudWork == false)
    #expect(defaults.boolValue(forKey: PodcastCloudSyncConsentStore.consentKey) == true)
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == "a")

    #expect(PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a")).hasConsent())
  }

  @Test func aDifferentTokenStillClearsConsentAfterAnUnreadableRead() {
    let defaults = MemoryConsentDefaults()
    PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a")).grant()
    #expect(
      PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity(.unreadable)).hasConsent() == false)

    #expect(PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("b")).hasConsent() == false)
    #expect(defaults.boolValue(forKey: PodcastCloudSyncConsentStore.consentKey) == false)
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == nil)
  }

  @Test func revokeRetainsNothingThatCouldReenable() {
    let defaults = MemoryConsentDefaults()
    let store = PodcastCloudSyncConsentStore(defaults: defaults, identity: FixedIdentity("a"))
    store.grant()
    store.revoke()
    #expect(store.hasConsent() == false)
    #expect(defaults.stringValue(forKey: PodcastCloudSyncConsentStore.installTokenKey) == nil)
  }

  @Test func observationYieldsCurrentValueThenChangesOnly() async {
    let store = PodcastCloudSyncConsentStore(defaults: MemoryConsentDefaults(), identity: FixedIdentity("a"))
    var iterator = store.observeConsent().makeAsyncIterator()
    #expect(await iterator.next() == false)
    store.revoke()  // unchanged: no yield
    store.grant()
    #expect(await iterator.next() == true)
    store.grant()  // unchanged: no yield
    store.revoke()
    #expect(await iterator.next() == false)
  }

  @Test func gateRequiresBothReadinessAndConsent() {
    let store = PodcastCloudSyncConsentStore(defaults: MemoryConsentDefaults(), identity: FixedIdentity("a"))
    store.grant()
    #expect(PodcastCloudSyncGate(consent: store, destinationReady: false).allowsCloudWork == false)
    #expect(PodcastCloudSyncGate(consent: store, destinationReady: true).allowsCloudWork)
    #expect(PodcastCloudSyncGate(consent: store).allowsCloudWork == PodcastDataSettingsReadiness.iCloudSync)
  }

  @Test func productionReadinessOffersICloudSyncAndBackups() {
    // Flipping either constant is an owner decision recorded in the plan; this pins the record.
    #expect(PodcastDataSettingsReadiness.iCloudSync)
    #expect(PodcastDataSettingsReadiness.backups)
    #expect(PodcastDataSettingsReadiness.automaticBackups)
    #expect(PodcastDataSettingsPresentation.visibleRows() == [.iCloudSync, .backups])
  }

  @Test func visibleRowsFollowReadiness() {
    #expect(PodcastDataSettingsPresentation.visibleRows(iCloudSyncReady: true, backupsReady: false) == [.iCloudSync])
    #expect(PodcastDataSettingsPresentation.visibleRows(iCloudSyncReady: false, backupsReady: true) == [.backups])
    #expect(
      PodcastDataSettingsPresentation.visibleRows(iCloudSyncReady: true, backupsReady: true)
        == [.iCloudSync, .backups])
    #expect(PodcastDataSettingsPresentation.iCloudSyncRowValue(isEnabled: false) == "Off")
    #expect(PodcastDataSettingsPresentation.iCloudSyncRowValue(isEnabled: true) == "On")
  }
}

@MainActor
@Suite struct PodcastCloudSyncConsentModelTests {
  private func makeModel(identity: String? = "a") -> (PodcastCloudSyncConsentModel, PodcastCloudSyncConsentStore) {
    let store = PodcastCloudSyncConsentStore(defaults: MemoryConsentDefaults(), identity: FixedIdentity(identity))
    return (PodcastCloudSyncConsentModel(store: store), store)
  }

  @Test func requestingEnableOpensConfirmationWithoutGranting() {
    let (model, store) = makeModel()
    model.requestEnabled(true)
    #expect(model.isConfirmingEnable)
    #expect(model.isEnabled == false)
    #expect(store.hasConsent() == false)
  }

  @Test func cancelLeavesTheSwitchOffAndWritesNothing() {
    let (model, store) = makeModel()
    model.requestEnabled(true)
    model.cancelEnable()
    #expect(model.isConfirmingEnable == false)
    #expect(model.isEnabled == false)
    #expect(store.hasConsent() == false)
  }

  @Test func confirmGrantsAndTurningOffRevokesImmediately() {
    let (model, store) = makeModel()
    model.requestEnabled(true)
    model.confirmEnable()
    #expect(model.isEnabled)
    #expect(store.hasConsent())

    model.requestEnabled(false)
    #expect(model.isConfirmingEnable == false)
    #expect(model.isEnabled == false)
    #expect(store.hasConsent() == false)
  }

  @Test func confirmWithoutAnOpenConfirmationGrantsNothing() {
    let (model, store) = makeModel()
    model.confirmEnable()
    #expect(model.isEnabled == false)
    #expect(store.hasConsent() == false)
  }

  @Test func confirmWithoutAnInstallIdentityFailsClosed() {
    let (model, store) = makeModel(identity: nil)
    model.requestEnabled(true)
    model.confirmEnable()
    #expect(model.isEnabled == false)
    #expect(model.enableFailed)
    #expect(store.hasConsent() == false)
    model.dismissEnableFailure()
    #expect(model.enableFailed == false)
  }
}

@Suite struct PodcastIntroductionPresentationTests {
  @Test func presentsOncePerVersionOnlyWhileNativeSubscriptionsAreEnabled() {
    #expect(PodcastIntroductionPresentation.shouldPresent(seenVersion: nil, nativeSubscriptionsEnabled: true))
    #expect(PodcastIntroductionPresentation.shouldPresent(seenVersion: 0, nativeSubscriptionsEnabled: true))
    #expect(PodcastIntroductionPresentation.shouldPresent(seenVersion: nil, nativeSubscriptionsEnabled: false) == false)
    #expect(
      PodcastIntroductionPresentation.shouldPresent(
        seenVersion: PodcastIntroductionPresentation.currentVersion, nativeSubscriptionsEnabled: true) == false)
  }

  @Test func rowsFollowTheServerAccount() {
    #expect(
      PodcastIntroductionPresentation.rows(hasServerAccount: false) == [PodcastIntroductionCopy.followRow])
    #expect(
      PodcastIntroductionPresentation.rows(hasServerAccount: true) == [
        PodcastIntroductionCopy.followRow, PodcastIntroductionCopy.libraryRow,
      ])
    #expect(
      PodcastIntroductionPresentation.lede(hasServerAccount: false) == PodcastIntroductionCopy.deviceLede)
    #expect(
      PodcastIntroductionPresentation.lede(hasServerAccount: true) == PodcastIntroductionCopy.serverLede)
  }

  /// Sync is explained in Settings next to its controls, so the sheet never mentions it and never
  /// has to track `PodcastDataSettingsReadiness`.
  @Test func rowsNeverDescribeSync() {
    for hasServerAccount in [false, true] {
      let rowText = PodcastIntroductionPresentation.rows(hasServerAccount: hasServerAccount)
        .map { $0.title + " " + $0.detail }.joined(separator: " ")
      let text = rowText + PodcastIntroductionPresentation.lede(hasServerAccount: hasServerAccount)
      #expect(text.localizedCaseInsensitiveContains("sync") == false)
      #expect(text.localizedCaseInsensitiveContains("iCloud") == false)
    }
  }

  @Test func markingSeenPersistsTheCurrentVersion() {
    let defaults = MemoryIntroductionDefaults()
    let preference = PodcastIntroductionPreference(defaults: defaults)
    #expect(preference.seenVersion() == nil)
    preference.markSeen()
    #expect(preference.seenVersion() == PodcastIntroductionPresentation.currentVersion)
    #expect(
      PodcastIntroductionPresentation.shouldPresent(
        seenVersion: preference.seenVersion(), nativeSubscriptionsEnabled: true) == false)
    #expect(AlreadySeenPodcastIntroduction().seenVersion() == PodcastIntroductionPresentation.currentVersion)
  }
}

private struct FixedIdentity: DeviceInstallIdentity {
  let read: DeviceInstallTokenRead
  init(_ read: DeviceInstallTokenRead) { self.read = read }
  /// `nil` is the readable-but-absent outcome: no token exists and none could be minted.
  init(_ token: String?) { read = token.map(DeviceInstallTokenRead.token) ?? .absent }
  func currentToken() -> DeviceInstallTokenRead { read }
}

private final class MemoryConsentDefaults: PodcastCloudSyncConsentDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]

  func boolValue(forKey key: String) -> Bool? { read(key) as? Bool }
  func setBoolValue(_ value: Bool, forKey key: String) { write(key, value) }
  func stringValue(forKey key: String) -> String? { read(key) as? String }
  func setStringValue(_ value: String, forKey key: String) { write(key, value) }
  func removeValue(forKey key: String) { write(key, nil) }

  private func read(_ key: String) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  private func write(_ key: String, _ value: Any?) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}

private final class MemoryIntroductionDefaults: PodcastIntroductionDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Int] = [:]

  func integerValue(forKey key: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  func setIntegerValue(_ value: Int, forKey key: String) {
    lock.lock()
    values[key] = value
    lock.unlock()
  }
}
