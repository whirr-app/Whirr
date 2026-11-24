import ABSApi
import Foundation
import Persistence

/// A device the current account may send ebooks to, as AppModel sees it: a server label and
/// nothing else.
public struct EbookDeliveryDevice: Sendable, Hashable {
  public let name: String

  public init(name: String) {
    self.name = name
  }
}

/// SyncEngine's reading of a send attempt. `uncertain` means the request may have reached the
/// server without an answer; the server's send is not idempotent, so it is never retried.
public enum EbookDeliveryOutcome: Sendable, Equatable {
  public enum NotSentReason: Sendable, Equatable {
    case serverEmailUnavailable
    case rejectedByMailServer
    case notPermitted
    case deviceNotFound
    case noEbookFile
    case unreachable
    case signInRequired
    case refused
  }

  case sent
  case notSent(NotSentReason)
  case uncertain

  init(_ result: EbookDeliveryResult) {
    switch result {
    case .sent: self = .sent
    case .uncertain: self = .uncertain
    case .notSent(let failure):
      switch failure {
      case .serverEmailUnavailable: self = .notSent(.serverEmailUnavailable)
      case .rejectedByMailServer: self = .notSent(.rejectedByMailServer)
      case .notPermitted: self = .notSent(.notPermitted)
      case .deviceNotFound: self = .notSent(.deviceNotFound)
      case .noEbookFile: self = .notSent(.noEbookFile)
      case .unreachable: self = .notSent(.unreachable)
      case .signInRequired: self = .notSent(.signInRequired)
      case .refused, .invalidRequest: self = .notSent(.refused)
      }
    }
  }
}

/// AppModel's boundary onto the server's send-ebook-to-device feature. Neither call throws: a
/// device read that fails is an empty list, and a send always resolves to an outcome.
public protocol EbookDelivering: Sendable {
  /// The devices the current account may send to, possibly from a recent read.
  func ereaderDevices() async -> [EbookDeliveryDevice]
  func sendEbook(itemID: String, deviceName: String) async -> EbookDeliveryOutcome
}

/// Default for graphs with no live account: no devices, so no menu entry.
public struct NoOpEbookDelivering: EbookDelivering, Sendable {
  public init() {}
  public func ereaderDevices() async -> [EbookDeliveryDevice] { [] }
  public func sendEbook(itemID: String, deviceName: String) async -> EbookDeliveryOutcome {
    .notSent(.signInRequired)
  }
}

/// The two `ABSClient` routes this service uses, narrowed so tests need no live client.
public protocol EbookDeliveryClient: Sendable {
  func fetchEreaderDevices(
    account: TokenAccount, diagnostics: DecodeDiagnostics?
  ) async throws -> [EreaderDevice]
  func sendEbookToDevice(
    account: TokenAccount, libraryItemID: String, deviceName: String
  ) async -> EbookDeliveryResult
}

extension ABSClient: EbookDeliveryClient {}

/// Reads the device list lazily and keeps it for `maximumDeviceAge`, keyed by account so a
/// replaced account never sees another's list. No timer or foreground hook: the menu asks when
/// about to show (API-CONVENTIONS rule 20).
///
/// Sends are single-flight per item and device, so a double tap emails once. Nothing is retried:
/// the server's send is not idempotent.
public actor EbookDeliveryService: EbookDelivering {
  public static let defaultMaximumDeviceAge: TimeInterval = 10 * 60

  private struct CachedDevices {
    let account: TokenAccount
    let devices: [EbookDeliveryDevice]
    let readAt: Date
  }

  private struct DeviceRead {
    let account: TokenAccount
    let epoch: UInt64
    let task: Task<[EbookDeliveryDevice]?, Never>
  }

  private struct SendKey: Hashable {
    let itemID: String
    let deviceName: String
  }

  private let client: any EbookDeliveryClient
  private let accountDAO: AccountDAO
  private let now: @Sendable () -> Date
  private let maximumDeviceAge: TimeInterval
  private var cached: CachedDevices?
  private var deviceRead: DeviceRead?
  private var epoch: UInt64 = 0
  private var sends: [SendKey: Task<EbookDeliveryOutcome, Never>] = [:]
  /// Test observation only: how many calls joined a send already in flight.
  private(set) var joinedSendCount = 0

  public init(
    client: any EbookDeliveryClient,
    database: AppDatabase,
    now: @escaping @Sendable () -> Date = Date.init,
    maximumDeviceAge: TimeInterval = EbookDeliveryService.defaultMaximumDeviceAge
  ) {
    self.client = client
    self.accountDAO = AccountDAO(database: database)
    self.now = now
    self.maximumDeviceAge = maximumDeviceAge
  }

  public func ereaderDevices() async -> [EbookDeliveryDevice] {
    guard let account = await currentAccount() else { return [] }
    if let cached, cached.account == account,
      now().timeIntervalSince(cached.readAt) < maximumDeviceAge
    {
      return cached.devices
    }

    let read: DeviceRead
    if let deviceRead, deviceRead.account == account {
      read = deviceRead
    } else {
      let client = self.client
      read = DeviceRead(
        account: account,
        epoch: epoch,
        task: Task {
          try? await client.fetchEreaderDevices(account: account, diagnostics: nil)
            .map { EbookDeliveryDevice(name: $0.name) }
        })
      deviceRead = read
    }

    let devices = await read.task.value
    if deviceRead?.task == read.task { deviceRead = nil }
    // A read that began before an invalidation may describe a device that has since gone; it can
    // answer its own callers but must not become the cache.
    if let devices, read.epoch == epoch {
      cached = CachedDevices(account: account, devices: devices, readAt: now())
    }
    return devices ?? []
  }

  public func sendEbook(itemID: String, deviceName: String) async -> EbookDeliveryOutcome {
    // Registered before the first suspension, so a second tap always finds the first send.
    let key = SendKey(itemID: itemID, deviceName: deviceName)
    let task: Task<EbookDeliveryOutcome, Never>
    if let existing = sends[key] {
      joinedSendCount += 1
      task = existing
    } else {
      let client = self.client
      let accountDAO = self.accountDAO
      task = Task {
        guard let account = await Self.account(from: accountDAO) else {
          return .notSent(.signInRequired)
        }
        return EbookDeliveryOutcome(
          await client.sendEbookToDevice(
            account: account, libraryItemID: itemID, deviceName: deviceName))
      }
      sends[key] = task
    }

    let result = await task.value
    if sends[key] == task { sends[key] = nil }
    if result == .notSent(.deviceNotFound) { invalidateDevices() }
    return result
  }

  private func invalidateDevices() {
    epoch &+= 1
    cached = nil
    deviceRead = nil
  }

  private func currentAccount() async -> TokenAccount? {
    await Self.account(from: accountDAO)
  }

  private static func account(from accountDAO: AccountDAO) async -> TokenAccount? {
    guard let record = try? await accountDAO.fetchAsync() else { return nil }
    return try? tokenAccount(for: record)
  }
}
