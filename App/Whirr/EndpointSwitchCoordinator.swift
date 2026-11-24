import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

/// Coordinates endpoint selection with the lifetime of the App's runtime composition.
@MainActor
@Observable
final class EndpointSwitchCoordinator {
  enum Reason: Sendable {
    case coldLaunch
    case foreground
    case reconnect
    case idleUnreachable
    /// The device joined a different network. A fallback address that still answers there (a
    /// VPN at home) would otherwise never yield to the preferred one.
    case networkChanged
  }

  @ObservationIgnored private let selector: EndpointSelector
  @ObservationIgnored private let isRuntime: @MainActor () -> Bool
  @ObservationIgnored private let isAuthRecoveryIdle: @MainActor () -> Bool
  @ObservationIgnored private let isPlaybackActive: @MainActor () -> Bool
  @ObservationIgnored private let hasActiveTransfersClosure: @MainActor @Sendable () async -> Bool

  private(set) var switchGeneration = 0
  private(set) var deferredSwitch = false

  init(
    accountDAO: AccountDAO,
    accountEndpointDAO: AccountEndpointDAO,
    tokenStore: any TokenStoring,
    customHeaderStore: any CustomHeaderStoring,
    isRuntime: @escaping @MainActor () -> Bool = { true },
    isAuthRecoveryIdle: @escaping @MainActor () -> Bool = { true },
    isPlaybackActive: @escaping @MainActor () -> Bool,
    hasActiveTransfers: @escaping @MainActor @Sendable () async -> Bool,
    preferenceWindow: TimeInterval = 2,
    probeTimeout: TimeInterval = ServerReachabilityMonitor.probeTimeout,
    sleep: @escaping @Sendable (TimeInterval) async -> Void = {
      try? await Task.sleep(for: .seconds($0))
    },
    now: @escaping @Sendable () -> Date = Date.init,
    probe: (@Sendable (AccountEndpointRecord) async throws -> Void)? = nil
  ) {
    self.isRuntime = isRuntime
    self.isAuthRecoveryIdle = isAuthRecoveryIdle
    self.isPlaybackActive = isPlaybackActive
    hasActiveTransfersClosure = hasActiveTransfers

    let serverConfigFactory = ABSServerConfigFactory(customHeaderStore: customHeaderStore)
    let endpointProbe: @Sendable (AccountEndpointRecord) async throws -> Void =
      probe ?? { endpoint in
        guard let url = URL(string: endpoint.normalizedURL) else {
          throw URLError(.badURL)
        }
        let server = try serverConfigFactory.make(for: url)
        let client = ABSClient.production(
          server: server,
          tokenStore: tokenStore,
          customHeaderStore: customHeaderStore,
          authEventObserving: NoOpAuthEventObserving(),
          serverReachabilityObserving: NoOpServerReachabilityObserving())
        _ = try await client.fetchServerStatus()
      }
    selector = EndpointSelector(
      accountDAO: accountDAO,
      accountEndpointDAO: accountEndpointDAO,
      probe: endpointProbe,
      preferenceWindow: preferenceWindow,
      probeTimeout: probeTimeout,
      sleep: sleep,
      now: now)
  }

  /// Runs a selection only for an eligible runtime composition. A switch may update the durable
  /// active endpoint while playback or a transfer is busy, but the composition rebuild waits.
  func trigger(_ reason: Reason) async {
    guard isRuntime(), isAuthRecoveryIdle() else { return }
    if case .idleUnreachable = reason {
      if isPlaybackActive() { return }
      if await hasActiveTransfersClosure() { return }
    }

    let hadDeferredSwitch = deferredSwitch
    switch await selector.select() {
    case .switched:
      await finishSwitchIfIdle()
    case .unchanged:
      if hadDeferredSwitch {
        await finishSwitchIfIdle()
      }
    case .noAccount, .singleEndpoint, .nothingAnswered:
      break
    }
  }

  /// Finishes a rebuild that playback or a transfer deferred, once both are idle. Without this a
  /// deferred switch waited for some unrelated later trigger.
  func completeDeferredSwitchIfIdle() async {
    guard deferredSwitch, isRuntime() else { return }
    await finishSwitchIfIdle()
  }

  private func finishSwitchIfIdle() async {
    guard isPlaybackActive() == false, await hasActiveTransfersClosure() == false else {
      deferredSwitch = true
      return
    }
    deferredSwitch = false
    switchGeneration += 1
  }
}
