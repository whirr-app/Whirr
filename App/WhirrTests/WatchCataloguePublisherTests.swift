import AppModel
import Foundation
import Persistence
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch catalogue publisher")
struct WatchCataloguePublisherTests {
  @Test("publication is injected and signed-out stop emits an empty snapshot")
  func publicationCallbackReceivesSignedOutSnapshot() throws {
    var emitted: WatchCatalogueSnapshot?
    let publisher = WatchCataloguePublisher(
      publish: { snapshot in emitted = snapshot })

    publisher.stopAndPublishSignedOut()

    let result = try #require(emitted)
    #expect(result.accountStamp == nil)
    #expect(result.items.isEmpty)
  }

}

@MainActor
@Suite("Watch catalogue publisher lifecycle", .serialized)
struct WatchCataloguePublisherLifecycleTests {

  @Test("phone preferences publish, refresh without playback, and clear at logout")
  func playbackPreferencesFollowDefaultsChanges() async throws {
    let suite = "watch-preferences-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream), defaults: defaults,
      // The publisher defers a publication that follows a recent one by whatever is left of its
      // 500ms minimum interval. At the stock interval a publication scheduled here can land a third
      // of a second after the wait that observed its predecessor returned, long enough to be
      // mistaken below for a republication the unrelated write caused. Shrink the interval so every
      // scheduled publication lands inside the debounce floor, well within the quiescence windows.
      minimumPublicationInterval: .milliseconds(20),
      publish: { snapshot in publications.append(snapshot) })
    defer { publisher.stop() }
    publisher.start()
    identities.continuation.yield(Self.account(id: 7, clientUUID: "preferences", server: "server"))
    #expect(await waitUntil("default preferences") { publications.last?.skipBackwardSeconds == 15 })
    #expect(publications.last?.skipForwardSeconds == SkipIntervalConfiguration.defaultForwardSeconds)
    #expect(publications.last?.playbackRatePresets == PlaybackRatePresetConfiguration.defaults)
    // Absent from the suite means on, the documented default.
    #expect(publications.last?.removePlayedNativeEpisodes == true)

    defaults.set(10, forKey: SkipIntervalConfiguration.backwardStorageKey)
    defaults.set(45, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set("1.35,1,0.9,1.1,1", forKey: "player.playbackRate.presets")
    defaults.set(false, forKey: WatchEpisodeSendPreferences.removesPlayedEpisodesKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(
      await waitUntil("updated independent skip intervals") {
        publications.last?.skipBackwardSeconds == 10 && publications.last?.skipForwardSeconds == 45
          && publications.last?.playbackRatePresets == [0.9, 1, 1.1, 1.35]
          && publications.last?.removePlayedNativeEpisodes == false
      })
    #expect(publications.last?.playbackState == .idle)
    // `waitUntil` returns on the first publication that satisfies it, which says nothing about
    // whether the burst behind it has finished. The baseline has to be a settled count, or the
    // unrelated write below is blamed for a publication that was already on its way.
    #expect(
      await awaitQuiescence("preference change settles", stableFor: 150) {
        String(publications.count)
      }.isObserved)

    // The setting alone must republish: flipping it back is its own change, not one carried by
    // the skip intervals above.
    defaults.set(true, forKey: WatchEpisodeSendPreferences.removesPlayedEpisodesKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(
      await waitUntil("flipping the setting republishes") {
        publications.last?.removePlayedNativeEpisodes == true
      })
    #expect(
      await awaitQuiescence("setting flip settles", stableFor: 150) {
        String(publications.count)
      }.isObserved)

    let count = publications.count
    defaults.set(true, forKey: "unrelated-preference")
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(
      await awaitQuiescence("unrelated defaults do not republish", stableFor: 150) {
        String(publications.count)
      }.isObserved)
    #expect(publications.count == count)

    identities.continuation.yield(nil)
    #expect(await waitUntil("signed out") { publications.last?.accountStamp == nil })
    #expect(publications.last?.skipBackwardSeconds == nil)
    #expect(publications.last?.playbackRatePresets == nil)
  }

  @Test("identity and bookmark observations publish an account-stamped row")
  func signedInIdentityAndBookmarkPublishSnapshot() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let bookmarks = FakePlaybackBookmarkStoring()
    let identityReading = StreamAccountIdentityReading(stream: identities.stream)
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      bookmarks: bookmarks,
      accountIdentity: identityReading,
      publish: { snapshot in publications.append(snapshot) })
    let account = Self.account(id: 1, clientUUID: "client-a", server: "server-a")

    publisher.start()
    identities.continuation.yield(account)
    await bookmarks.observationRecorder.waitUntil(count: 1)
    bookmarks.push(Self.bookmark(itemID: "book-a", title: "Book A"))

    #expect(
      await waitUntil("account-stamped bookmark publication") {
        publications.contains { snapshot in
          snapshot.accountStamp != nil
            && snapshot.items.contains { $0.title == "Book A" }
        }
      })
    let latest = try #require(publications.last)
    #expect(latest.accountStamp != nil)
    #expect(latest.items.contains { $0.title == "Book A" })
  }

  @Test("native bookmarks wait for the enabled preference before publication")
  func nativeBookmarkWaitsForPreference() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let bookmarks = FakePlaybackBookmarkStoring()
    let enabled = FakeNativePodcastSubscriptionsReading(enabled: nil)
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      bookmarks: bookmarks,
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream),
      nativeSubscriptions: enabled,
      publish: { snapshot in publications.append(snapshot) })
    defer { publisher.stop() }
    publisher.start()
    identities.continuation.yield(Self.account(id: 5, clientUUID: "native-client", server: "server"))
    await bookmarks.observationRecorder.waitUntil(count: 1)
    bookmarks.push(
      PlaybackBookmark(
        serverItemId: "rss:3", episodeID: "episode", episodeTitle: "Native episode",
        title: "Native show", author: nil, durationSeconds: 100, positionSeconds: 10, isFinished: false))
    #expect(await waitUntil("account publication before preference") { publications.last?.accountStamp != nil })
    #expect(
      await awaitQuiescence("bookmark observation settles", stableFor: 100) {
        String(publications.count)
      }.isObserved)
    #expect(publications.allSatisfy { $0.items.isEmpty })
    // Until the preference is read the Watch is not offered followed shows.
    #expect(publications.allSatisfy { $0.followedPodcastsEnabled != true })

    enabled.stubEnabled(true)
    #expect(
      await waitUntil("enabled native bookmark") {
        publications.last?.items.contains { $0.selection == .nativeFeed(feedID: "3", episodeID: "episode") } == true
      })
    #expect(publications.last?.followedPodcastsEnabled == true)
    enabled.stubEnabled(false)
    #expect(await waitUntil("disabled native bookmark removed") { publications.last?.items.isEmpty == true })
    #expect(publications.last?.followedPodcastsEnabled == false)
  }

  @Test("logout emits empty immediately and a stale bookmark cannot repopulate it")
  func logoutClearsRowsBeforeStaleBookmarkCanReturn() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let bookmarks = FakePlaybackBookmarkStoring()
    let identityReading = StreamAccountIdentityReading(stream: identities.stream)
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      bookmarks: bookmarks,
      accountIdentity: identityReading,
      publish: { snapshot in publications.append(snapshot) })
    let account = Self.account(id: 2, clientUUID: "client-a", server: "server-a")

    publisher.start()
    identities.continuation.yield(account)
    await bookmarks.observationRecorder.waitUntil(count: 1)
    bookmarks.push(Self.bookmark(itemID: "book-a", title: "Old Book"))
    #expect(
      await waitUntil("initial account row") {
        publications.last?.items.contains { $0.title == "Old Book" } == true
      })

    identities.continuation.yield(nil)
    #expect(
      await waitUntil("signed-out empty publication") {
        guard let snapshot = publications.last else { return false }
        return snapshot.accountStamp == nil && snapshot.items.isEmpty
      })
    let signedOutIndex = publications.count - 1

    // This value belongs to the old account and is sent after the signed-out fence.
    bookmarks.push(Self.bookmark(itemID: "book-a", title: "Old Book"))
    #expect(
      await awaitQuiescence("signed-out catalogue remains empty", stableFor: 100) {
        String(publications.count)
      }.isObserved)
    #expect(
      publications.dropFirst(signedOutIndex).allSatisfy {
        $0.accountStamp == nil && $0.items.isEmpty
      })
  }

  @Test("account replacement fails closed, then a fresh publisher starts the new account")
  func replacementUsesFreshPublisherWithoutRelabelingOldRows() async throws {
    let oldIdentities = AsyncStream<AccountIdentity?>.makeStream()
    let oldBookmarks = FakePlaybackBookmarkStoring()
    let oldIdentityReading = StreamAccountIdentityReading(stream: oldIdentities.stream)
    var oldPublications: [WatchCatalogueSnapshot] = []
    let oldPublisher = WatchCataloguePublisher(
      bookmarks: oldBookmarks,
      accountIdentity: oldIdentityReading,
      publish: { snapshot in oldPublications.append(snapshot) })
    let first = Self.account(id: 3, clientUUID: "client-a", server: "server-a")
    let second = Self.account(id: 4, clientUUID: "client-b", server: "server-b")

    oldPublisher.start()
    oldIdentities.continuation.yield(first)
    await oldBookmarks.observationRecorder.waitUntil(count: 1)
    oldBookmarks.push(Self.bookmark(itemID: "book-a", title: "First Account"))
    #expect(
      await waitUntil("first account row") {
        oldPublications.last?.items.contains { $0.title == "First Account" } == true
      })

    // AccountIdentityReading belongs to the environment that created this publisher. A changed
    // identity must clear the old projection rather than relabeling its row with the new stamp.
    oldIdentities.continuation.yield(second)
    #expect(
      await waitUntil("replacement fails closed") {
        guard let snapshot = oldPublications.last else { return false }
        return snapshot.accountStamp == nil && snapshot.items.isEmpty
      })
    let oldPublicationCount = oldPublications.count
    #expect(oldPublications.last?.items.contains { $0.title == "First Account" } == false)

    // RootComposition creates a fresh publisher with fresh account-scoped readers on replacement.
    let newIdentities = AsyncStream<AccountIdentity?>.makeStream()
    let newBookmarks = FakePlaybackBookmarkStoring()
    let newIdentityReading = StreamAccountIdentityReading(stream: newIdentities.stream)
    var newPublications: [WatchCatalogueSnapshot] = []
    let newPublisher = WatchCataloguePublisher(
      bookmarks: newBookmarks,
      accountIdentity: newIdentityReading,
      publish: { snapshot in newPublications.append(snapshot) })

    newPublisher.start()
    newIdentities.continuation.yield(second)
    await newBookmarks.observationRecorder.waitUntil(count: 1)
    newBookmarks.push(Self.bookmark(itemID: "book-b", title: "Second Account"))
    #expect(
      await waitUntil("second account row") {
        newPublications.last?.items.contains { $0.title == "Second Account" } == true
      })
    #expect(newPublications.last?.items.contains { $0.title == "First Account" } == false)
    #expect(oldPublications.count == oldPublicationCount)
  }

  /// The 50ms debounce coalesces a burst but not a sustained feed. A change every 60ms cleared it
  /// each time, so the publisher ran at the rate its upstreams changed: nine persisted
  /// observations re-running through a sync burst, and a playhead tick twice a second.
  @Test("a sustained upstream feed cannot publish faster than the minimum interval")
  func sustainedFeedIsRateLimited() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let bookmarks = FakePlaybackBookmarkStoring()
    var publications: [WatchCatalogueSnapshot] = []
    var publishedAt: [ContinuousClock.Instant] = []
    let publisher = WatchCataloguePublisher(
      bookmarks: bookmarks,
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream),
      minimumPublicationInterval: .milliseconds(200),
      publish: { snapshot in
        publications.append(snapshot)
        publishedAt.append(.now)
      })
    defer { publisher.stop() }
    publisher.start()
    identities.continuation.yield(Self.account(id: 9, clientUUID: "cadence", server: "server"))
    #expect(await waitUntil("first publication") { publications.isEmpty == false })
    let baseline = publications.count

    // Sixteen changes at 60ms: faster than the 200ms floor, slower than the 50ms debounce, so
    // without the floor every one of them would publish on its own.
    for index in 0..<16 {
      bookmarks.push(Self.bookmark(itemID: "book-\(index)", title: "Book \(index)"))
      try await Task.sleep(for: .milliseconds(60))
    }
    #expect(
      await waitUntil("the final change publishes") {
        publications.last?.items.contains { $0.title == "Book 15" } == true
      })

    // Gaps, not a count: load stretches the stimulus and so changes how many publications there
    // are. A sleep never ends early, so no load can close a gap below the floor. The 10ms slack
    // covers stamping the instant in this closure rather than where the publisher records it.
    let gaps = zip(publishedAt.dropFirst(baseline), publishedAt.dropFirst(baseline + 1)).map { $1 - $0 }
    #expect(gaps.isEmpty == false, "the floor must not stop publication")
    #expect(gaps.allSatisfy { $0 >= .milliseconds(190) }, "publication gaps \(gaps)")
  }

  /// A change landing while a catalogue assembles must wait a full floor from that catalogue's
  /// emission. Measured from when assembly began, a slow assembly would use up most of the floor
  /// before anything reached the Watch, so the next publication would follow it closely.
  @Test("a change during a slow assembly still waits the full interval after it emits")
  func slowAssemblyCannotShortenTheNextGap() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let bookmarks = FakePlaybackBookmarkStoring()
    let floor = Duration.milliseconds(300)
    let assemblies = Locked(0)
    let firstAssemblyStartedAt = Locked<ContinuousClock.Instant?>(nil)
    let released = Locked(false)
    var publications: [WatchCatalogueSnapshot] = []
    var publishedAt: [ContinuousClock.Instant] = []
    let publisher = WatchCataloguePublisher(
      bookmarks: bookmarks,
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream),
      minimumPublicationInterval: floor,
      publish: { snapshot in
        publications.append(snapshot)
        publishedAt.append(.now)
      },
      assemble: { assembly in
        let isFirst = assemblies.withValue { count in
          count += 1
          return count == 1
        }
        if isFirst {
          firstAssemblyStartedAt.value = .now
          let deadline = Date().addingTimeInterval(5)
          while released.value == false, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        }
        return assembly.makeSnapshot()
      })
    defer {
      released.value = true
      publisher.stop()
    }
    publisher.start()
    identities.continuation.yield(Self.account(id: 13, clientUUID: "slow-assembly", server: "server"))
    #expect(await waitUntil("first assembly started") { firstAssemblyStartedAt.value != nil })
    let startedAt = try #require(firstAssemblyStartedAt.value)

    // The change arrives while the first catalogue is still assembling, and that assembly then
    // takes most of the floor. The second publication must still follow its emission by a floor.
    bookmarks.push(Self.bookmark(itemID: "book-slow", title: "Slow Book"))
    try await Task.sleep(until: startedAt + .milliseconds(180), clock: .continuous)
    released.value = true

    #expect(
      await waitUntil("the change publishes") {
        publications.last?.items.contains { $0.title == "Slow Book" } == true
      })
    try #require(publishedAt.count >= 2)
    let gap = publishedAt[1] - publishedAt[0]
    // The same 10ms slack as the sustained-feed test, for stamping in this closure.
    #expect(gap >= floor - .milliseconds(10), "publication gap \(gap)")
  }

  /// Merging the shelves, building the catalogue and mapping it to the wire is the bulk of a
  /// publication. While audio plays it runs twice a second, and on the main thread it drops frames
  /// from any scroll in the app.
  @Test("the catalogue is assembled off the main thread")
  func assemblyRunsOffTheMainThread() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let assembledOnMain = Locked<[Bool]>([])
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream),
      publish: { snapshot in publications.append(snapshot) },
      assemble: { assembly in
        assembledOnMain.withValue { $0.append(Thread.isMainThread) }
        return assembly.makeSnapshot()
      })
    defer { publisher.stop() }
    publisher.start()
    identities.continuation.yield(Self.account(id: 11, clientUUID: "off-main", server: "server"))

    #expect(await waitUntil("account publication") { publications.last?.accountStamp != nil })
    #expect(assembledOnMain.value.isEmpty == false)
    #expect(assembledOnMain.value.allSatisfy { $0 == false })
  }

  /// Assembly finishes after the main actor has moved on, so the epoch fence must also hold at the
  /// point of publication: a sign-out must not be followed by the old account's rows.
  @Test("a publication still assembling when the publisher stops is never emitted")
  func assemblyFinishingAfterStopIsDropped() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let started = Locked(false)
    let released = Locked(false)
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      accountIdentity: StreamAccountIdentityReading(stream: identities.stream),
      publish: { snapshot in publications.append(snapshot) },
      assemble: { assembly in
        started.value = true
        let deadline = Date().addingTimeInterval(5)
        while released.value == false, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        return assembly.makeSnapshot()
      })
    publisher.start()
    identities.continuation.yield(Self.account(id: 12, clientUUID: "stopping", server: "server"))
    #expect(await waitUntil("assembly started") { started.value })

    publisher.stop()
    released.value = true

    await awaitQuiescence("late assembly settles", stableFor: 100) { "\(publications.count)" }
    #expect(publications.isEmpty)
  }

  private static func account(id: Int64, clientUUID: String, server: String) -> AccountIdentity {
    AccountIdentity(id: id, clientUUID: clientUUID, serverIdentityFingerprint: server)
  }

  private static func bookmark(itemID: String, title: String) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, title: title, author: "Author", durationSeconds: 100,
      positionSeconds: 10, isFinished: false)
  }
}

private final class StreamAccountIdentityReading: AccountIdentityReading, @unchecked Sendable {
  private let stream: AsyncStream<AccountIdentity?>

  init(stream: AsyncStream<AccountIdentity?>) {
    self.stream = stream
  }

  func observeAccountIdentity() -> AsyncStream<AccountIdentity?> {
    stream
  }
}

/// The line the Watch runs its clock along between publications, and when the phone's playhead has
/// left it far enough that the Watch must be told at once instead of at the next 15 s tick.
@MainActor
@Suite("Watch published playhead")
struct WatchPublishedPlayheadTests {
  private let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let threshold = WatchCataloguePublisher.playheadDepartureThreshold

  private func playhead(position: Double = 100, rate: Double = 1) -> WatchCataloguePublisher.PublishedPlayhead {
    .init(position: position, at: at, rate: rate)
  }

  @Test("playback at the published rate stays on the line")
  func steadyPlaybackStaysOnTheLine() {
    #expect(!playhead().isDeparted(by: 110, at: at.addingTimeInterval(10)))
    #expect(!playhead(rate: 1.5).isDeparted(by: 115, at: at.addingTimeInterval(10)))
    #expect(!playhead().isDeparted(by: 110 + threshold, at: at.addingTimeInterval(10)))
  }

  @Test("a seek or skip either way leaves the line")
  func jumpsLeaveTheLine() {
    #expect(playhead().isDeparted(by: 140, at: at.addingTimeInterval(10)))
    #expect(playhead().isDeparted(by: 95, at: at.addingTimeInterval(10)))
  }

  @Test("trimmed silence drifting ahead leaves the line once past the threshold")
  func driftLeavesTheLineOncePastTheThreshold() {
    #expect(!playhead().isDeparted(by: 111.5, at: at.addingTimeInterval(10)))
    #expect(playhead().isDeparted(by: 112.5, at: at.addingTimeInterval(10)))
  }

  @Test("a paused playhead stays still, so moving it leaves the line")
  func pausedPlayheadIsStill() {
    #expect(!playhead(rate: 0).isDeparted(by: 100, at: at.addingTimeInterval(60)))
    #expect(playhead(rate: 0).isDeparted(by: 130, at: at.addingTimeInterval(1)))
  }

  @Test("a clock read before the publication does not run the line backwards")
  func earlierClockHoldsThePublishedPosition() {
    #expect(!playhead().isDeparted(by: 100, at: at.addingTimeInterval(-5)))
  }
}
