import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import UIKit

extension AppEnvironment {
  struct ArtworkComposition {
    let serverConfig: ABSServerConfig
    let preparedArtworkScope: ArtworkAccountScope
    let coverImageClient: CoverImageClient
    let rssArtworkClient: RSSArtworkClient
    let artworkClient: ProviderArtworkClient
    let clearCachedArtwork: @Sendable () async -> Void
    /// The account's one owner of cover colour, for the shell's surfaces and the background
    /// writers alike. It lives as long as this composition, which `RootView` replaces at every
    /// account boundary.
    let paletteService: CoverPaletteService
  }

  /// Keys decoded covers, compressed covers and persisted palettes. Derived from the account's
  /// credential namespace, never its address, so switching between a LAN and a VPN address of the
  /// same server keeps every cover; a different account is still a different scope.
  nonisolated static func preparedArtworkScope(for account: AccountRecord?) -> ArtworkAccountScope {
    guard let account else { return ArtworkAccountScope("abs:none") }
    return ArtworkAccountScope(
      "abs:\(account.credentialNamespace)#account=\(account.id.map(String.init) ?? "none")")
  }

  static func makeArtworkComposition(
    account: AccountRecord?,
    serverConfigFactory: ABSServerConfigFactory,
    feedCredentialStore: any FeedCredentialStoring,
    coverPaletteRecordStore: CoverPaletteRecordStore
  ) -> ArtworkComposition {
    let serverConfig = Self.serverConfig(for: account, factory: serverConfigFactory)
    let preparedArtworkScope = Self.preparedArtworkScope(for: account)
    let coverImageClient = CoverImageClient(
      server: serverConfig,
      cacheDirectory: CoverImageClient.disposableCacheDirectoryURL,
      artworkScope: preparedArtworkScope)
    let rssArtworkClient = RSSArtworkClient(
      authorization: RSSArtworkAuthorization(credentialStore: feedCredentialStore))
    let artworkClient = ProviderArtworkClient(
      abs: coverImageClient,
      rss: rssArtworkClient)
    let paletteService = CoverPaletteService(
      recordStore: coverPaletteRecordStore, coverClient: artworkClient,
      admission: CoverPaletteWriter.sharedAdmission)
    let clearCachedArtwork: @Sendable () async -> Void = {
      await coverImageClient.clearCachedArtwork()
      // Then the rows, then the in-memory palettes, in the order the service keeps.
      await paletteService.clearCachedArtwork()
    }

    return ArtworkComposition(
      serverConfig: serverConfig,
      preparedArtworkScope: preparedArtworkScope,
      coverImageClient: coverImageClient,
      rssArtworkClient: rssArtworkClient,
      artworkClient: artworkClient,
      clearCachedArtwork: clearCachedArtwork,
      paletteService: paletteService)
  }
}
