import ABSApi
import AppModel
import Foundation
import Persistence
import PlayerCore
import SyncEngine

extension AppEnvironment {
  struct EndpointComposition {
    let serverAddressesModel: ServerAddressesModel
    let endpointSwitchCoordinator: EndpointSwitchCoordinator
  }

  /// Runtime-only endpoint selection: Settings' server-address model, the switch coordinator, and
  /// the auth-recovery model's "try other addresses" actions bound to that coordinator.
  @MainActor
  static func makeEndpointComposition(
    database: AppDatabase,
    accountDAO: AccountDAO,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    serverConfigFactory: ABSServerConfigFactory,
    client: ABSClient,
    recoveryModel: AuthRecoveryModel,
    hardware: PlaybackHardware,
    downloadCoordinator: DownloadCoordinator
  ) -> EndpointComposition {
    let endpointService = AccountEndpointService(
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      serverConfigFactory: serverConfigFactory,
      candidateClientFactory: { config, tokenStore in
        ABSClient.production(
          server: config,
          tokenStore: tokenStore,
          customHeaderStore: customHeaderStore,
          authEventObserving: NoOpAuthEventObserving(),
          serverReachabilityObserving: NoOpServerReachabilityObserving())
      },
      refreshLiveTokens: { tokenAccount in
        try await client.refreshTokens(for: tokenAccount)
      })
    let serverAddressesModel = ServerAddressesModel(
      service: endpointService,
      activeURL: { (try? accountDAO.fetch())?.serverBaseURL })

    let endpointCoordinator = EndpointSwitchCoordinator(
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      isAuthRecoveryIdle: { recoveryModel.state == .idle },
      isPlaybackActive: {
        switch hardware.player.state.phase {
        case .preparing, .buffering, .playing, .seeking, .stalled:
          true
        default:
          false
        }
      },
      hasActiveTransfers: { await downloadCoordinator.hasActiveTransfers() })
    recoveryModel.bindOtherAddressActions(
      canTryOtherAddresses: {
        guard let accountID = (try? accountDAO.fetch())?.id else { return false }
        return (try? AccountEndpointDAO(database: database).fetchAll(accountId: accountID).count > 1) ?? false
      },
      tryOtherAddresses: { [weak endpointCoordinator] in
        guard let endpointCoordinator else { return }
        await endpointCoordinator.trigger(.reconnect)
      })
    return EndpointComposition(
      serverAddressesModel: serverAddressesModel,
      endpointSwitchCoordinator: endpointCoordinator)
  }
}
