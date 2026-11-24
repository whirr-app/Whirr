import ABSApi
import AppModel
import CloudKit
import Foundation
import Persistence
import SyncEngine
import UIKit

/// A per-installation token in a `ThisDeviceOnly`, non-synchronizable Keychain item. Those items
/// are not carried to another device by iCloud backup, encrypted Finder backup or device-to-device
/// transfer, which is what lets `PodcastCloudSyncConsentStore` treat a restored or migrated
/// installation as having never consented. The token is random and carries no user data.
final class KeychainDeviceInstallIdentity: DeviceInstallIdentity, @unchecked Sendable {
  static let defaultService = "com.remoteconcern.whirr.device-install-identity"
  static let account = "install-token"

  private let client: any SecItemClient
  private let query: KeychainItemQuery
  private let lock = NSLock()
  private var cached: String?

  /// `SecuritySecItemClient` looks items up with `kSecAttrSynchronizableAny`, but every item it
  /// adds is non-synchronizable and this service name is new to this build, so no synchronizable
  /// item can exist under it to be mistaken for the install identity.
  init(client: any SecItemClient = SecuritySecItemClient(), service: String = defaultService) {
    self.client = client
    query = KeychainItemQuery(service: service, account: Self.account)
  }

  /// Reads the existing token or mints one. A read that throws (any status but not-found, such as
  /// before first unlock) is `.unreadable` and is not cached, so the next read retries; the consent
  /// store then changes nothing. A readable, empty item that cannot be minted into is `.absent`,
  /// which the store treats as "cannot consent on this device" rather than inventing a volatile
  /// token.
  func currentToken() -> DeviceInstallTokenRead {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return .token(cached) }
    let data: Data?
    do {
      data = try client.copyData(for: query)
    } catch {
      return .unreadable
    }
    if let data, let token = String(data: data, encoding: .utf8), token.isEmpty == false {
      cached = token
      return .token(token)
    }
    let token = UUID().uuidString.lowercased()
    do {
      try client.add(
        KeychainItemAttributes(service: query.service, account: query.account, data: Data(token.utf8)),
        for: query)
    } catch {
      return .absent
    }
    cached = token
    return .token(token)
  }

  /// Test support: forgets the item so a fresh token is minted on the next read.
  func reset() throws {
    lock.lock()
    defer { lock.unlock() }
    cached = nil
    try client.delete(for: query)
  }
}

/// The installation identity's durable anchor: a second `ThisDeviceOnly` item beside the consent
/// token, since consent's item survives `revoke()` while this value is ordering-critical. Like
/// `KeychainDeviceInstallIdentity.currentToken()`, it reports "readable and definitively empty"
/// (`nil`) apart from every other failure (thrown). That is the restore signal: absence means the
/// database crossed devices without the Keychain, and an error imitating absence would re-mint the
/// installation on an ordinary launch.
final class KeychainPodcastCloudInstallationAnchor: PodcastCloudInstallationAnchor, @unchecked Sendable {
  static let defaultService = "com.remoteconcern.whirr.podcast-cloud-installation"
  static let account = "installation-uuid"

  private let client: any SecItemClient
  private let query: KeychainItemQuery
  private let lock = NSLock()

  init(client: any SecItemClient = SecuritySecItemClient(), service: String = defaultService) {
    self.client = client
    query = KeychainItemQuery(service: service, account: Self.account)
  }

  /// No caching: a cached value would outlive a `write` from another resolution, or a restore that
  /// removed the item. Stored bytes that are not a UUID read as absence, which re-mints and
  /// overwrites them (self-healing); throwing would refuse to sync until the user reinstalled.
  func read() throws -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try client.copyData(for: query) else { return nil }
    return UUID(uuidString: String(decoding: data, as: UTF8.self))
  }

  /// Update-or-add: `add` throws `itemAlreadyExists` on a duplicate, which the "database absent,
  /// anchor present" case hits on every reinstall over a surviving Keychain item.
  func write(_ uuid: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    let attributes = KeychainItemAttributes(
      service: query.service, account: query.account, data: Data(uuid.uuidString.utf8))
    do {
      try client.add(attributes, for: query)
    } catch KeychainStoreError.itemAlreadyExists {
      try client.update(attributes, for: query)
    }
  }

  /// Test support: forgets the item so the next resolution sees the restore signature.
  func reset() throws {
    lock.lock()
    defer { lock.unlock() }
    try client.delete(for: query)
  }
}

/// One consent store for the whole process, so the Settings switch, the introduction sheet and
/// the cloud service lifetime all observe the same object. Constructing it opens nothing: the
/// Keychain item is only touched on the first consent read or grant.
enum PodcastCloudSyncComposition {
  static let installIdentity = KeychainDeviceInstallIdentity()
  static let installationAnchor = KeychainPodcastCloudInstallationAnchor()
  static let consentStore = PodcastCloudSyncConsentStore(
    defaults: UserDefaults.standard, identity: installIdentity)

  /// Whether this build offers iCloud sync at all.
  static let destinationReady = PodcastDataSettingsReadiness.iCloudSync

  /// Debug and Release share the container but not the database: `WhirrDebug.entitlements` selects
  /// the Development environment and `Whirr.entitlements`, the TestFlight build, Production
  /// (ADR 0009, TestFlight amendment 2026-11-08). The environment is part of the sync namespace,
  /// so an install that moves between them runs the bootstrap barrier again rather than reusing
  /// engine state from the other database.
  static func destination(debugBuild: Bool) -> PodcastCloudSyncRuntime.Destination {
    PodcastCloudSyncRuntime.Destination(
      container: "iCloud.com.remoteconcern.whirr",
      environment: debugBuild ? "development" : "production", zone: "PodcastState")
  }

  #if DEBUG
    static let destination = destination(debugBuild: true)
  #else
    static let destination = destination(debugBuild: false)
  #endif

  /// The only question a cloud service may ask before constructing an engine or sending anything.
  static var gate: PodcastCloudSyncGate {
    PodcastCloudSyncGate(consent: consentStore, destinationReady: destinationReady)
  }

  /// Handed to the refresh path at composition time; the runtime points it at each session.
  nonisolated static let refreshRelay = PodcastCloudRefreshRelay()

  /// The one "what's playing right now" marker for the process. RSS playback reports into it and
  /// the sync runtime reads it, so the playing episode's listening beats a remote reset; it lives
  /// here because this composition exists before any account does.
  nonisolated static let activePlaybackTracker = RSSActivePlaybackTracker()

  /// The live sync lifetime, or `nil` in a build that does not offer sync. Constructing it opens
  /// nothing in CloudKit, which is first touched when a consented session starts.
  ///
  /// Also `nil`, and not yet built, while the store cannot open: a scene can activate before the
  /// first unlock since boot. A later read builds it.
  static var runtime: PodcastCloudSyncRuntime? {
    if let builtRuntime { return builtRuntime }
    guard destinationReady, let database = DatabaseHardware.sharedIfAvailable() else { return nil }
    let runtime = makeRuntime(database: database)
    builtRuntime = runtime
    return runtime
  }

  private static var builtRuntime: PodcastCloudSyncRuntime?

  private static func makeRuntime(database: AppDatabase) -> PodcastCloudSyncRuntime {
    let destination = Self.destination
    let zoneID = CKRecordZone.ID(zoneName: destination.zone, ownerName: CKCurrentUserDefaultName)
    return PodcastCloudSyncRuntime(
      database: database,
      anchor: installationAnchor,
      consent: consentStore,
      destinationReady: destinationReady,
      destination: destination,
      account: PodcastCloudKitAccountReading(containerIdentifier: destination.container),
      epochs: UserDefaultsPodcastCloudAccountEpochStore(),
      lastSync: UserDefaultsPodcastCloudLastSyncStore(),
      refreshRelay: refreshRelay,
      backgroundTime: PodcastCloudLifecycleBackgroundTime(lifecycle: AppEnvironment.sharedLifecycle),
      activeEpisodeRowIDs: { activePlaybackTracker.activeEpisodeRowIDs },
      makeKeyringStore: {
        PodcastCloudKitKeyringStore(
          database: CKContainer(identifier: destination.container).privateCloudDatabase,
          zoneID: zoneID)
      },
      makeEngine: { coordinator in
        await MainActor.run {
          // `CKSyncEngine` converges on silent pushes; the entitlement and the
          // `remote-notification` background mode are in every build.
          UIApplication.shared.registerForRemoteNotifications()
          return PodcastCloudKitSyncEngineAdapter(handler: coordinator)
        }
      })
  }

  /// The running service behind the iCloud Sync screen's Status, Try Again and deletion controls.
  static var syncController: (any PodcastCloudSyncControlling)? { runtime }

  /// Follows consent and the iCloud account for the life of the calling task. Call once at launch,
  /// after the installation identity has been resolved.
  static func runForLaunch() async {
    guard let runtime else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await runtime.run() }
      group.addTask {
        for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
          await runtime.accountDidChange()
        }
      }
    }
  }
}
