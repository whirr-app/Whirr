import Foundation
import WatchPlayback
import WatchProtocol

/// Credentials are accepted only in a live reply exchange. Only the non-secret receipt survives
/// relaunch, allowing a lost acknowledgement to be retried without reinstalling rotated tokens.
/// The receipt is protected state: before first unlock it cannot be read, and setup then answers
/// busy rather than treating it as absent and discarding it.
@MainActor
final class WatchSetupReceiver {
  private static let receiptKey = "watch.setup.receipt.v1"
  private let store: WatchProtectedFileStore
  /// False while the receipt file exists but could not be read.
  private var receiptKnown: Bool
  private let currentAccount: () -> WatchAccountStamp?
  private let install: (WatchSetupCredentials) async throws -> Void
  private let isInstalled: (WatchAccountStamp) async -> Bool
  private let health: () -> WatchLinkHealth?
  private var admission: WatchSetupAdmission
  private var processing = false
  private var generation = 0

  init(
    store: WatchProtectedFileStore,
    currentAccount: @escaping () -> WatchAccountStamp?,
    install: @escaping (WatchSetupCredentials) async throws -> Void,
    isInstalled: @escaping (WatchAccountStamp) async -> Bool,
    health: @escaping () -> WatchLinkHealth? = { nil }
  ) {
    self.store = store
    self.currentAccount = currentAccount
    self.install = install
    self.isInstalled = isInstalled
    self.health = health
    let read = Self.readReceipt(from: store)
    receiptKnown = read.isSettled
    admission = Self.admission(for: read)
  }

  private static func readReceipt(from store: WatchProtectedFileStore) -> WatchProtectedRead<WatchSetupReceipt> {
    store.read(key: receiptKey) {
      try WatchWireCodec.decode(WatchSetupReceipt.self, from: $0)
    }
  }

  private static func admission(for read: WatchProtectedRead<WatchSetupReceipt>) -> WatchSetupAdmission {
    let receipt = read.value
    return WatchSetupAdmission(receipt: receipt?.status == .installed ? receipt : nil)
  }

  /// Retries a receipt that could not be read at launch. Nothing has been admitted while it was
  /// unknown, because setup answered busy, so the fresh admission replaces nothing.
  private func settleReceipt() -> Bool {
    guard !receiptKnown else { return true }
    let read = Self.readReceipt(from: store)
    guard read.isSettled else { return false }
    receiptKnown = true
    admission = Self.admission(for: read)
    return true
  }

  func receive(_ data: Data, key: String) async -> Data? {
    guard data.count <= WatchSetupCredentials.maxWireBytes else { return nil }
    if key == WatchTransportKey.setupHello { return receiveHello(data) }
    if key == WatchTransportKey.setupStatus { return await receiveStatus(data) }
    guard key == WatchTransportKey.setupCredentials,
      let credentials = try? WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
    else { return nil }
    return await admitCredentials(credentials)
  }

  /// The hello/challenge exchange. It stays synchronous: it only reads and rewrites the in-memory
  /// admission and the receipt file, and granting a challenge clears a stale receipt at once.
  private func receiveHello(_ data: Data) -> Data? {
    guard let hello = try? WatchWireCodec.decode(WatchSetupHello.self, from: data) else { return nil }
    if processing || !settleReceipt() {
      return try? WatchWireCodec.encode(
        WatchSetupChallenge(
          id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: Date(), status: .busy))
    }
    let challenge = admission.begin(hello, existingAccount: currentAccount(), now: Date())
    if challenge.status == .ready { try? store.clear(key: Self.receiptKey) }
    return try? WatchWireCodec.encode(challenge)
  }

  private func receiveStatus(_ data: Data) async -> Data? {
    guard let hello = try? WatchWireCodec.decode(WatchSetupHello.self, from: data) else { return nil }
    // A probe reports the Watch's provisioning and nothing else: it must not consume the
    // outstanding challenge or the persisted receipt, so an in-flight install stays retryable.
    guard !processing else {
      return try? WatchWireCodec.encode(
        WatchSetupChallenge(
          id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: Date(), status: .busy))
    }
    // Reports what the Watch already knows; starting a library load here would race the
    // WatchConnectivity reply timeout.
    let installed = await isInstalled(hello.accountStamp)
    return try? WatchWireCodec.encode(
      WatchSetupAdmission.status(
        for: hello, existingAccount: currentAccount(), isInstalled: installed, now: Date(), health: health()))
  }

  /// Admission and install. `processing` covers the whole install, and the generation re-check
  /// fences one that a reset superseded while it was awaiting.
  private func admitCredentials(_ credentials: WatchSetupCredentials) async -> Data? {
    guard !processing, settleReceipt() else { return receipt(for: credentials, status: .busy) }
    if let account = currentAccount(), account != credentials.accountStamp {
      return receipt(for: credentials, status: .wrongAccount)
    }
    let admittedAt = Date()
    guard let duplicate = try? admission.admit(credentials, now: admittedAt) else {
      return receipt(for: credentials, status: .rejected)
    }
    processing = true
    let token = generation
    defer { processing = false }
    do {
      if duplicate {
        guard await isInstalled(credentials.accountStamp), token == generation else {
          return receipt(for: credentials, status: .rejected)
        }
        return receipt(for: credentials, status: .installed)
      }
      try await install(credentials)
      guard token == generation else { return receipt(for: credentials, status: .rejected) }
      // Expiry gates admission, before the install starts; slow local storage must not turn a
      // verified installation into an ambiguous failure after that deadline.
      let installed = try admission.complete(credentials, now: admittedAt)
      let encoded = try WatchWireCodec.encode(installed)
      // The account is installed whatever this write says; a lost receipt only costs the phone's
      // retry the duplicate shortcut, and its status probe still reports the installation.
      do { try store.save(encoded, key: Self.receiptKey) } catch {
        WatchDiagnostics.record(.protectedStateWriteFailed)
      }
      return encoded
    } catch {
      return receipt(for: credentials, status: .rejected)
    }
  }

  func reset() {
    generation &+= 1
    admission = WatchSetupAdmission()
    do {
      try store.clear(key: Self.receiptKey)
      receiptKnown = true
    } catch {
      receiptKnown = false
    }
  }

  private func receipt(for credentials: WatchSetupCredentials, status: WatchSetupStatus) -> Data? {
    try? WatchWireCodec.encode(
      WatchSetupReceipt(
        id: credentials.id, accountStamp: credentials.accountStamp, nonce: credentials.nonce, status: status))
  }
}
