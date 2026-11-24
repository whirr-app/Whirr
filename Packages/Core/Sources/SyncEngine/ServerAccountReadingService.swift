import ABSApi
import Foundation
import Persistence

/// The production account-settings reader. It owns the conversion from the durable database and
/// ABSApi's live profile DTO into the narrow AppModel boundary. Neither raw records nor wire values
/// escape this target (ARCHITECTURE.md).
public struct ServerAccountReadingService: ServerAccountReading, Sendable {
  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let libraryDAO: LibraryDAO
  private let libraryReading: DefaultLibraryReading
  private let customHeaderStore: any CustomHeaderStoring

  public init(
    client: ABSClient,
    database: AppDatabase,
    customHeaderStore: any CustomHeaderStoring
  ) {
    self.client = client
    accountDAO = AccountDAO(database: database)
    libraryDAO = LibraryDAO(database: database)
    libraryReading = DefaultLibraryReading(database: database)
    self.customHeaderStore = customHeaderStore
  }

  public func readDurableSettings() async throws -> ServerAccountDurableSettings {
    guard let account = try await accountDAO.fetchAsync(), let accountID = account.id else {
      throw ServerAccountReadingError.notAuthenticated
    }
    guard let serverURL = URL(string: account.serverBaseURL) else {
      throw ServerAccountReadingError.malformedAccount
    }

    let libraries = try await libraryDAO.fetchAccessibleAsync(accountId: accountID).map {
      ServerAccountLibrary(id: $0.serverLibraryId, name: $0.name, mediaType: $0.mediaType)
    }
    let syncStatus = await currentAggregateSyncStatus()
    let storedHeaders = try customHeaderStore.load(for: serverURL)
    let headerNames = storedHeaders?.headerFields.keys.sorted() ?? []

    return ServerAccountDurableSettings(
      serverVersion: account.serverVersion,
      libraries: libraries,
      syncStatus: syncStatus,
      customHeaders: CustomHeaderSummary(names: headerNames)
    )
  }

  public func fetchProfile() async throws -> ServerAccountProfile {
    guard let account = try await accountDAO.fetchAsync(), account.id != nil else {
      throw ServerAccountReadingError.notAuthenticated
    }
    let tokenAccount: TokenAccount
    do {
      tokenAccount = try account.credentialTokenAccount
    } catch {
      throw ServerAccountReadingError.malformedAccount
    }

    let profile = try await client.fetchUserProfile(account: tokenAccount)
    return ServerAccountProfile(
      username: profile.username,
      type: profile.type,
      librariesAccessible: profile.librariesAccessible
    )
  }

  /// `DefaultLibraryReading` already owns the account-wide aggregation policy. Taking its first
  /// observation keeps this reader on the same projection as the rest of the app, including the
  /// oldest-library completion semantics documented by `LibrarySyncStatus`.
  private func currentAggregateSyncStatus() async -> LibrarySyncStatus {
    for await status in libraryReading.observeAggregateSyncStatus() {
      return status
    }
    return LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil)
  }
}
