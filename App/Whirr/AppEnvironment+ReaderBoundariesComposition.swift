import AppModel
import Foundation
import Persistence
import ReaderCore
import SyncEngine

extension AppEnvironment {
  /// The reader's boundaries, the per-title speed settings, and the reader's progress access.
  ///
  /// Core's `AppDependencies` is frozen at the renderer boundary, so these stay in the App
  /// composition; detail and reader views receive the same instances for the lifetime of one
  /// environment. `readerProgress` needs the playback composition's item-progress coordinator,
  /// so this is built on the runtime path immediately after `makePlaybackComposition`.
  struct ReaderBoundariesComposition {
    let readerStateReading: any ReaderStateReading
    let supplementReading: any ItemSupplementReading
    let readerTableOfContents: any EPUBTableOfContentsReading
    let readerContentsAccess: any EbookTableOfContentsAccess
    let readerProgress: any ReaderProgressAccessing
    let readerPreferencesStore: any ReaderPreferencesStoring
    let trimSilencesShowSettings: RoutingTrimSilencesShowSettingsAccess?
    let voiceBoostShowSettings: RoutingVoiceBoostShowSettingsAccess?
  }

  @MainActor
  static func makeReaderBoundariesComposition(
    database: AppDatabase,
    downloadRootURL: URL,
    account: AccountRecord?,
    itemProgress: ItemProgressCoordinator
  ) -> ReaderBoundariesComposition {
    let readerStateReading: any ReaderStateReading = DefaultReaderStateReading(
      database: database, downloadRootURL: downloadRootURL)
    // Both spines merged: the account's own show setting and the device-owned RSS one.
    let trimSilencesShowSettings = account?.id.map {
      RoutingTrimSilencesShowSettingsAccess(
        abs: PodcastSettingsStore(database: database, accountId: $0),
        rss: RSSFeedSettingsStore(database: database))
    }
    let voiceBoostShowSettings = account?.id.map {
      RoutingVoiceBoostShowSettingsAccess(
        abs: PodcastSettingsStore(database: database, accountId: $0),
        rss: RSSFeedSettingsStore(database: database))
    }
    let supplementReading: any ItemSupplementReading = ItemSupplementStore(
      database: database, downloadRootURL: downloadRootURL)
    let readerTableOfContents: any EPUBTableOfContentsReading = ReadiumTableOfContentsExtractor()
    let readerContentsAccess: any EbookTableOfContentsAccess = DefaultEbookTableOfContentsAccess(
      database: database)
    let readerPreferencesStore: any ReaderPreferencesStoring
    if let accountID = account?.id {
      readerPreferencesStore = ReaderPreferencesStore(database: database, accountId: accountID)
    } else {
      readerPreferencesStore = NoOpReaderPreferencesStore()
    }
    let readerProgress: any ReaderProgressAccessing
    if let accountID = account?.id {
      readerProgress = DefaultReaderProgressAccess(
        database: database, accountID: accountID,
        coordinator: itemProgress)
    } else {
      readerProgress = NoOpReaderProgressAccess()
    }

    return ReaderBoundariesComposition(
      readerStateReading: readerStateReading,
      supplementReading: supplementReading,
      readerTableOfContents: readerTableOfContents,
      readerContentsAccess: readerContentsAccess,
      readerProgress: readerProgress,
      readerPreferencesStore: readerPreferencesStore,
      trimSilencesShowSettings: trimSilencesShowSettings,
      voiceBoostShowSettings: voiceBoostShowSettings)
  }
}
