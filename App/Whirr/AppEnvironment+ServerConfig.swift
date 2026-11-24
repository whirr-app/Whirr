import ABSApi
import Foundation
import Persistence

extension AppEnvironment {
  /// The account row names the server; the Keychain item `ABSServerConfigFactory` reads only adds
  /// proxy headers. A throwing read (`AfterFirstUnlockThisDeviceOnly` items are unreadable before
  /// first unlock; an unsigned host gets `errSecMissingEntitlement`) costs the headers alone.
  /// Falling back to the unconfigured literal would point the client, artwork and downloads at a
  /// server the user never configured and key `PodcastBackgroundRefreshHardware.sharedServices` on
  /// it, composing a second `DownloadCoordinator` once headers read. The literal therefore means
  /// only: no account, or an invalid stored URL.
  static func serverConfig(
    for account: AccountRecord?, factory: ABSServerConfigFactory
  ) -> ABSServerConfig {
    if let account, let url = URL(string: account.serverBaseURL) {
      if let config = try? factory.make(for: url) {
        return config
      }
      if let headerlessConfig = try? factory.make(for: url, customHeaders: .none) {
        return headerlessConfig
      }
    }
    // A fixed, well-formed literal can never fail `ABSServerConfig.init`, so this cannot throw.
    return try! ABSServerConfig(url: URL(string: "https://unconfigured.invalid")!)
  }

  nonisolated static func sharedServicesKey(server: ABSServerConfig, accountID: Int64?) -> String {
    "\(server.baseURL.absoluteString)#headers=\(server.customHeaders.fingerprint)#account=\(accountID.map(String.init) ?? "none")"
  }

  nonisolated static func applicationSupportDirectory() -> URL {
    DatabaseHardware.applicationSupportDirectory()
  }
}
