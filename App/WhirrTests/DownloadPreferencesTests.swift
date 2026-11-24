import Foundation
import SyncEngine
import Testing

@testable import Whirr

@Suite("Download preferences")
struct DownloadPreferencesTests {
  @Test("queue auto-download policy defaults to never and persists independently")
  func queueAutoDownloadPolicyDefaultsToNeverAndPersists() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    #expect(preferences.queueAutoDownloadPolicy == .never)

    await preferences.setQueueAutoDownloadPolicy(.always)

    #expect(preferences.queueAutoDownloadPolicy == .always)
    #expect(preferences.allowCellular == false)
    #expect(preferences.deleteWhenFinished == false)
  }

  @Test("queue auto-download policy changes reach every observer")
  func queueAutoDownloadPolicyChangesAreBroadcastToEveryObserver() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    let firstStream = preferences.queueAutoDownloadPolicyChanges
    let secondStream = preferences.queueAutoDownloadPolicyChanges
    let first = Task { await nextPolicyValue(from: firstStream) }
    let second = Task { await nextPolicyValue(from: secondStream) }

    await preferences.setQueueAutoDownloadPolicy(.wifiOnly)

    #expect(await first.value == .wifiOnly)
    #expect(await second.value == .wifiOnly)
  }

  @Test("delete when finished defaults off and persists independently")
  func deleteWhenFinishedDefaultsOffAndPersists() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    #expect(preferences.deleteWhenFinished == false)

    await preferences.setDeleteWhenFinished(true)

    #expect(preferences.deleteWhenFinished)
    #expect(preferences.allowCellular == false)
  }

  @Test("delete when finished changes reach every observer")
  func deleteWhenFinishedChangesAreBroadcastToEveryObserver() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    // Subscribe before creating the tasks: the streams register their continuations when built,
    // so evaluating them here means the broadcast below cannot outrun registration.
    let firstStream = preferences.deleteWhenFinishedChanges
    let secondStream = preferences.deleteWhenFinishedChanges
    let first = Task { await nextValue(from: firstStream) }
    let second = Task { await nextValue(from: secondStream) }

    await preferences.setDeleteWhenFinished(true)

    #expect(await first.value == true)
    #expect(await second.value == true)
  }

  @Test("a preference change reaches both the settings model and download coordinator observers")
  func changesAreBroadcastToEveryObserver() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    let firstStream = preferences.changes
    let secondStream = preferences.changes
    let first = Task { await nextValue(from: firstStream) }
    let second = Task { await nextValue(from: secondStream) }

    await preferences.setAllowCellular(true)

    #expect(await first.value == true)
    #expect(await second.value == true)
  }

  @Test("storage ceiling preference defaults unlimited and persists its byte value")
  func storageCeilingDefaultsUnlimitedAndPersists() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsDownloadPreferences(defaults: defaults)
    #expect(preferences.storageCeilingBytes == nil)

    await preferences.setStorageCeilingBytes(StorageCeiling.gigabytes(8).bytes)

    #expect(preferences.storageCeilingBytes == 8_000_000_000)
  }

  @Test("the last storage ceiling summary persists and is broadcast")
  func storageCeilingSummaryPersistsAndBroadcasts() async {
    let suiteName = "DownloadPreferencesTests-\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsStorageCeilingSummaryStore(defaults: defaults, accountId: 42)
    let stream = store.storageCeilingSummaryChanges
    let next = Task { await nextSummary(from: stream) }
    let summary = StorageCeilingEvictionSummary(
      capBytes: 100, removedBytes: 25, removedRows: 1, unmetBytes: 0)

    await store.storeStorageCeilingSummary(summary)

    #expect(store.lastStorageCeilingSummary == summary)
    #expect(await next.value == summary)
    #expect(
      UserDefaultsStorageCeilingSummaryStore(defaults: defaults, accountId: 42)
        .lastStorageCeilingSummary == summary)
  }
}

private func nextValue(from stream: AsyncStream<Bool>) async -> Bool? {
  var iterator = stream.makeAsyncIterator()
  return await iterator.next()
}

private func nextPolicyValue(
  from stream: AsyncStream<QueueAutoDownloadPolicy>
) async -> QueueAutoDownloadPolicy? {
  var iterator = stream.makeAsyncIterator()
  return await iterator.next()
}

private func nextSummary(
  from stream: AsyncStream<StorageCeilingEvictionSummary?>
) async -> StorageCeilingEvictionSummary? {
  var iterator = stream.makeAsyncIterator()
  // The element is itself optional, so the iterator hands back a double optional: the outer one is
  // "the stream ended", the inner one is "the summary was cleared". Both flatten to nil here.
  return await iterator.next() ?? nil
}
