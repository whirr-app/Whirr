import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import Persistence

/// ADR 0016: an active smart list plays before Up Next, and what ends or keeps its run.
@Suite(.timeLimit(.minutes(1)))
struct SmartListRunPlaybackModelTests {

  // MARK: - Completion

  @MainActor
  @Test("with a run, the list plays before a non-empty Up Next and Up Next is untouched")
  func listPlaysBeforeUpNext() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    world.player.pushProgress(Self.ended("show", "a"))
    await world.continuation.waitForRecordedStarts(1)

    #expect(world.model.loadedItemID == "show")
    #expect(world.model.loadedEpisodeID == "b")
    #expect(await world.queue.identities == [queued], "Up Next keeps every row")
    #expect(await world.queue.peekCount == 0)
    #expect(await world.continuation.anchor == "b", "a list advance moves the anchor on success")
    #expect(await world.continuation.endReasons.isEmpty)
    #expect(await world.continuation.excluded == [Self.identity("a")])
  }

  @MainActor
  @Test("a list episode that is also queued consumes its own row and no other")
  func listEpisodeQueueRowIsConsumed() async throws {
    let world = Self.makeWorld()
    let listed = Self.identity("b")
    let other = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, other), Self.row(2, listed)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    world.player.pushProgress(Self.ended("show", "a"))
    await world.queue.waitForAcknowledgements(3)

    #expect(await world.queue.identities == [other])
  }

  @MainActor
  @Test("the list running out ends the run and the same completion starts Up Next's head")
  func exhaustedListHandsOverToUpNext() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.sync.stubStartSession(.success(Self.prepared("book-1")))
    world.player.pushProgress(Self.ended("show", "a"))
    await world.queue.waitForAcknowledgements(3)

    #expect(await world.continuation.endReasons == [.listExhausted])
    #expect(await world.continuation.hasRun == false)
    #expect(world.model.loadedItemID == "book-1")
    #expect(await world.queue.identities.isEmpty)
  }

  @MainActor
  @Test("a sleep-timer completion prepares the run's next episode paused and leaves the run alone")
  func sleepTimerPreparesTheRunPaused() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    let intents = world.player.intents

    world.player.pushProgress(
      Self.ended("show", "a", endBehavior: .stop, sleepTimerExpiry: .expired))
    await world.continuation.waitForRecordedStarts(1)

    #expect(world.model.loadedEpisodeID == "b", "the run's next episode is prepared")
    #expect(Array(world.player.intents.dropFirst(intents.count)).contains(.play) == false)
    #expect(await world.continuation.nextCalls == 1)
    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.anchor == "b")
    #expect(await world.continuation.endReasons.isEmpty)
    #expect(await world.queue.identities == [queued], "Up Next keeps every row")
    #expect(await world.queue.peekCount == 0)
  }

  // MARK: - Preparing a continuation paused

  @MainActor
  @Test("a preparation consults the run first, pauses its next episode and keeps the run")
  func preparationFollowsTheRun() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    await world.model.stop()
    let generation = world.model.playbackGeneration
    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    let intents = world.player.intents

    await world.model.prepareContinuationPaused(
      after: Self.identity("a"), clearing: .everyRow, generation: generation)

    #expect(world.model.loadedEpisodeID == "b")
    #expect(Array(world.player.intents.dropFirst(intents.count)).contains(.play) == false)
    #expect(await world.continuation.nextCalls == 1)
    #expect(await world.continuation.hasRun, "a `.listAdvance` start never ends the run")
    #expect(await world.continuation.anchor == "b", "the run moved on with the prepared episode")
    #expect(await world.continuation.endReasons.isEmpty)
    #expect(await world.queue.identities == [queued], "Up Next is never consulted")
    #expect(await world.queue.peekCount == 0)
    #expect(world.model.startFailure == nil)
  }

  @MainActor
  @Test("a failed prepared list advance is presented as a list advance and keeps the run")
  func failedPreparationKeepsTheRun() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    await world.model.stop()
    let generation = world.model.playbackGeneration
    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))

    await world.model.prepareContinuationPaused(
      after: Self.identity("a"), clearing: .everyRow, generation: generation)

    #expect(world.model.startFailure?.origin == .listAdvance)
    #expect(world.model.phase == .recoverableError)
    #expect(world.model.nowPlayingIdentity == Self.identity("b"))
    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.anchor == "a")
    #expect(await world.continuation.endReasons.isEmpty)
    #expect(await world.queue.peekCount == 0, "a failed advance never falls to Up Next")
    #expect(await world.queue.identities == [queued])
  }

  /// A preparation taken before presence exists has no surface for a failure banner, so a failed
  /// list read only logs; nothing tries Up Next and nothing is presented.
  @MainActor
  @Test("a failed list read during a preparation sets nothing")
  func failedPreparationReadIsSilent() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(
      run: Self.run(anchor: "a"), next: [], readFails: true)
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    await world.model.stop()
    let generation = world.model.playbackGeneration

    await world.model.prepareContinuationPaused(
      after: Self.identity("a"), clearing: .everyRow, generation: generation)

    #expect(world.model.startFailure == nil)
    #expect(world.model.phase == .idle)
    #expect(world.model.activeItemID == nil)
    #expect(await world.continuation.hasRun)
    #expect(await world.queue.peekCount == 0)
    #expect(await world.queue.identities == [queued])
  }

  @MainActor
  @Test("a failed list advance keeps the run and anchor, stays silent, and never falls to Up Next")
  func failedAdvanceKeepsRunAndSkipsUpNext() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    world.player.pushProgress(Self.ended("show", "a"))
    await waitUntil { world.model.startFailureMessage != nil }

    #expect(world.model.startFailure?.origin == .listAdvance)
    #expect(world.model.phase == .recoverableError)
    #expect(world.model.nowPlayingIdentity == Self.identity("b"))
    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.anchor == "a")
    #expect(await world.continuation.endReasons.isEmpty)
    #expect(await world.queue.peekCount == 0, "a failed advance never consults Up Next")
    #expect(await world.queue.identities == [queued])
  }

  @MainActor
  @Test("Retry of a failed advance keeps the run and moves the anchor when it succeeds")
  func retryOfFailedAdvanceKeepsRun() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    world.player.pushProgress(Self.ended("show", "a"))
    await waitUntil { world.model.startFailureMessage != nil }

    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    world.model.retry()
    await world.continuation.waitForRecordedStarts(1)

    #expect(world.model.loadedEpisodeID == "b")
    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.anchor == "b")
    #expect(await world.continuation.endReasons.isEmpty)
  }

  @MainActor
  @Test("a failed read of the list is a failed advance, not an exhausted list")
  func failedReadIsNotExhaustion() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(
      run: Self.run(anchor: "a"), next: [], readFails: true)
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.player.pushProgress(Self.ended("show", "a"))
    await waitUntil { world.model.startFailureMessage != nil }

    #expect(world.model.startFailure?.origin == .listAdvance)
    #expect(await world.continuation.hasRun)
    #expect(await world.queue.peekCount == 0)
  }

  @MainActor
  @Test("with no available source completion ignores the run, keeps its row and plays Up Next")
  func noSourceIgnoresRun() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(
      run: Self.run(anchor: "a"), next: [Self.candidate("b")], available: false)
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")

    world.sync.stubStartSession(.success(Self.prepared("book-1")))
    world.player.pushProgress(Self.ended("show", "a"))
    await world.queue.waitForAcknowledgements(3)

    #expect(world.model.loadedItemID == "book-1")
    #expect(await world.continuation.nextCalls == 0)
    #expect(await world.continuation.hasRun, "the row is kept for when a source returns")
    #expect(await world.continuation.endReasons.isEmpty)
  }

  // MARK: - Beginning a run

  @MainActor
  @Test("a list Play begins its run only after the start succeeds")
  func beginWritesAfterSuccess() async throws {
    let world = Self.makeWorld()
    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    let failed = await world.model.startReportingSuccess(
      itemID: "show", episodeID: "a", run: .begin(listID: 7))
    #expect(failed == false)
    #expect(await world.continuation.recordedStarts.isEmpty)

    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    let succeeded = await world.model.startReportingSuccess(
      itemID: "show", episodeID: "a", run: .begin(listID: 7))
    #expect(succeeded)
    #expect(await world.continuation.recordedStarts == [Self.recorded("a", listID: 7)])
    #expect(await world.continuation.endedUnlessAnchored.isEmpty, "a list start never ends a run")
  }

  @MainActor
  @Test("a list Play of the episode that is already playing still begins the run")
  func beginOnTheActiveEpisode() async throws {
    let world = Self.makeWorld()
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    #expect(await world.continuation.recordedStarts.isEmpty)

    await world.model.start(itemID: "show", episodeID: "a", run: .begin(listID: 7))

    #expect(await world.continuation.recordedStarts == [Self.recorded("a", listID: 7)])
  }

  @MainActor
  @Test("Retry of a failed list Play begins the run")
  func retryOfFailedListPlayBegins() async throws {
    let world = Self.makeWorld()
    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    await world.model.start(itemID: "show", episodeID: "a", run: .begin(listID: 7))
    #expect(world.model.startFailure?.origin == .requested)
    #expect(await world.continuation.recordedStarts.isEmpty)

    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    world.model.retry()
    await world.continuation.waitForRecordedStarts(1)

    #expect(await world.continuation.recordedStarts == [Self.recorded("a", listID: 7)])
    #expect(await world.continuation.endedUnlessAnchored.isEmpty)
  }

  // MARK: - What ends a run

  @MainActor
  @Test("an Up Next row tap ends the run")
  func upNextRowTapEndsRun() async throws {
    let world = Self.makeWorld()
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    await world.queue.configure(rows: [Self.row(1, queued)])
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    #expect(await world.continuation.hasRun)

    // `ListeningQueueSheet.playNow`: a plain `start` of the row's identity.
    world.sync.stubStartSession(.success(Self.prepared("book-1")))
    await world.model.start(itemID: "book-1", episodeID: nil)

    #expect(await world.continuation.hasRun == false)
  }

  @MainActor
  @Test("another requested start ends the run, a failed one included")
  func otherRequestedStartEndsRun() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.stubStartSession(.success(Self.prepared("show", "z")))
    await world.model.start(itemID: "show", episodeID: "z")
    #expect(await world.continuation.hasRun == false)
  }

  @MainActor
  @Test("resuming the run's anchor, from the start too, keeps it, before any bookmark arrives")
  func resumingTheAnchorKeepsRun() async throws {
    // The model has no bookmark store: `latestBookmark` is nil throughout, as on a cold launch
    // before the observation delivers. Only the run's anchor can keep the run.
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))

    await world.model.start(itemID: "show", episodeID: "a")
    await world.model.start(itemID: "show", episodeID: "a", fromStart: true)

    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.endedUnlessAnchored.count == 2)
  }

  @MainActor
  @Test("immediately after a list advance, resuming the new anchor keeps the run")
  func resumingAfterAdvanceKeepsRun() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    world.sync.stubStartSession(.success(Self.prepared("show", "b")))
    world.player.pushProgress(Self.ended("show", "a"))
    await world.continuation.waitForRecordedStarts(1)

    await world.model.start(itemID: "show", episodeID: "b", fromStart: true)

    #expect(await world.continuation.hasRun)
    #expect(await world.continuation.anchor == "b")
  }

  @MainActor
  @Test("a CarPlay or Watch start of another episode ends the run")
  func companionStartEndsRun() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.stubStartSession(.success(Self.prepared("show", "z")))
    let actions = CompanionPlaybackActions(
      playback: world.model, player: world.player, account: world.account)
    let source = try #require(PodcastSourceIdentity.abs(itemId: "show"))

    // CarPlayPlaybackActions.play and WatchPhoneCommandEndpoint both call this.
    #expect(await actions.start(source: source, episodeID: "z") == .accepted)

    #expect(await world.continuation.hasRun == false)
  }

  @MainActor
  @Test("a Siri play(selection:) of another episode ends the run, and of the anchor keeps it")
  func siriSelectionEndsRun() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    let voice = VoicePlaybackActions(
      playback: world.model, player: world.player, account: world.account,
      bookmarkStore: NoOpPlaybackBookmarkStoring())
    let source = try #require(PodcastSourceIdentity.abs(itemId: "show"))

    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    _ = await voice.play(selection: CompanionSelection(source: source, episodeID: "a"))
    #expect(await world.continuation.hasRun, "the run's own episode keeps it")

    world.sync.stubStartSession(.success(Self.prepared("show", "z")))
    _ = await voice.play(selection: CompanionSelection(source: source, episodeID: "z"))
    #expect(await world.continuation.hasRun == false)
  }

  @MainActor
  @Test("automatic origins never end a run")
  func automaticOriginsNeverEnd() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.stubStartSession(.success(Self.prepared("show", "z")))
    await world.model.start(itemID: "show", episodeID: "z", origin: .queueAdvance)
    world.sync.stubStartSession(.success(Self.prepared("show", "y")))
    await world.model.start(itemID: "show", episodeID: "y", origin: .listAdvance)

    #expect(await world.continuation.hasRun)
    #expect(PlaybackStartFailure.Origin.listAdvance.isAutomatic)
    #expect(PlaybackStartFailure.Origin.queueAdvance.isAutomatic)
    #expect(PlaybackStartFailure.Origin.requested.isAutomatic == false)
  }

  // MARK: - Logout

  @MainActor
  @Test("logout quiesce blocks run writes from a start that was in flight")
  func logoutBlocksRunWrites() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [])
    world.sync.holdStartSession()
    let start = Task { @MainActor in
      await world.model.start(itemID: "show", episodeID: "a", run: .begin(listID: 7))
    }
    await world.sync.waitForCalls {
      $0.contains { if case .startSession = $0 { return true } else { return false } }
    }

    await world.model.prepareForLogout()
    world.sync.releaseStartSession(with: .success(Self.prepared("show", "a")))
    await start.value
    await world.model.start(itemID: "show", episodeID: "z", run: .begin(listID: 7))
    await world.model.start(itemID: "show", episodeID: "z")

    #expect(await world.continuation.recordedStarts.isEmpty)
    #expect(await world.continuation.endedUnlessAnchored.isEmpty)
    #expect(await world.continuation.hasRun)
  }

  @MainActor
  @Test("a completion that loses its generation to logout starts nothing from the list")
  func logoutDuringCompletionStartsNothing() async throws {
    let world = Self.makeWorld()
    await world.continuation.configure(run: Self.run(anchor: "a"), next: [Self.candidate("b")])
    world.sync.stubStartSession(.success(Self.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    await world.model.prepareForLogout()

    world.player.pushProgress(Self.ended("show", "a"))
    await Task.yield()

    #expect(await world.continuation.nextCalls == 0)
    #expect(await world.continuation.recordedStarts.isEmpty)
  }

  // MARK: - Fixtures

  struct World {
    let model: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let queue: RecordingListeningQueue
    let continuation: FakeContinuationSource
    let account: FakeAccountLifecycle
  }

  @MainActor
  static func makeWorld() -> World {
    let queue = RecordingListeningQueue()
    let continuation = FakeContinuationSource()
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let playback = PlaybackModelHarness(
      account: account, listeningQueue: queue, continuation: continuation)
    return World(
      model: playback.model, player: playback.player, sync: playback.sync, queue: queue,
      continuation: continuation, account: account)
  }

  static func identity(_ episodeID: String) -> ListeningIdentity {
    ListeningIdentity.podcastEpisode(itemID: "show", episodeID: episodeID)!
  }

  static func run(anchor: String) -> SmartListRunState {
    SmartListRunState(listID: 7, anchorItemID: "show", anchorEpisodeID: anchor)
  }

  static func recorded(_ episodeID: String, listID: Int64?) -> FakeContinuationSource.Recorded {
    .init(itemID: "show", episodeID: episodeID, listID: listID)
  }

  static func candidate(_ episodeID: String) -> SmartListCandidate {
    SmartListCandidate(
      episode: SmartListEpisode(
        source: .server, itemID: "show", episodeID: episodeID, showKey: "show", showTitle: "Show",
        showAuthor: nil, title: "Episode \(episodeID)", publishedAt: nil, durationSeconds: 100,
        progressSeconds: 0, status: .unplayed, isDownloaded: false, isSaved: false,
        isPriority: false, artworkURL: nil, artworkFeedURL: nil, showServerUpdatedAt: nil,
        sortKey: SmartListSortKey(
          order: .newest, isPriority: false, value: nil, source: .server, showKey: "show",
          episodeID: episodeID)))
  }

  static func ended(
    _ itemID: String, _ episodeID: String? = nil,
    endBehavior: PlaybackProgressEvent.EndBehavior = .advanceQueue,
    sleepTimerExpiry: PlaybackProgressEvent.SleepTimerExpiry = .none
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: 1, itemId: itemID, episodeID: episodeID, phase: .ended, currentTime: 100,
      listenedDelta: 1, endBehavior: endBehavior, sleepTimerExpiry: sleepTimerExpiry)
  }

  static func prepared(_ itemID: String, _ episodeID: String? = nil) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/audio.mp3")!, mimeType: "audio/mpeg",
          title: itemID)
      ], chapters: [])
  }

  static func row(_ id: Int64, _ identity: ListeningIdentity) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: false)
  }
}

/// Mirrors the real run row's semantics in memory: one run, a stored anchor, ended unless the
/// started identity is the anchor.
actor FakeContinuationSource: PlaybackContinuationSource {
  struct Recorded: Equatable, Sendable {
    let itemID: String
    let episodeID: String
    let listID: Int64?
  }
  struct ReadFailure: Error {}

  private var run: SmartListRunState?
  private var next: [SmartListCandidate] = []
  private var available = true
  private var readFails = false
  private nonisolated let starts = TestCountRecorder(label: "FakeContinuationSource starts")

  private(set) var endReasons: [SmartListRunEndReason] = []
  private(set) var endedUnlessAnchored: [Recorded] = []
  private(set) var recordedStarts: [Recorded] = []
  private(set) var excluded: [ListeningIdentity] = []
  private(set) var nextCalls = 0

  var hasRun: Bool { run != nil }
  var anchor: String? { run?.anchorEpisodeID }

  func configure(
    run: SmartListRunState?, next: [SmartListCandidate], available: Bool = true,
    readFails: Bool = false
  ) {
    self.run = run
    self.next = next
    self.available = available
    self.readFails = readFails
  }

  func currentRun() async -> SmartListRunState? { available ? run : nil }

  func nextEpisode(
    after run: SmartListRunState, excluding: ListeningIdentity
  ) async throws -> SmartListCandidate? {
    nextCalls += 1
    excluded.append(excluding)
    if readFails { throw ReadFailure() }
    return next.first
  }

  func endRun(reason: SmartListRunEndReason) async {
    endReasons.append(reason)
    run = nil
  }

  func endRunUnlessAnchored(itemID: String, episodeID: String?) async {
    endedUnlessAnchored.append(.init(itemID: itemID, episodeID: episodeID ?? "", listID: nil))
    guard let current = run else { return }
    if current.anchorItemID == itemID, current.anchorEpisodeID == episodeID { return }
    run = nil
  }

  func recordListStart(itemID: String, episodeID: String, listID: Int64?) async -> Bool {
    recordedStarts.append(.init(itemID: itemID, episodeID: episodeID, listID: listID))
    starts.record()
    let list = listID ?? run?.listID
    guard let list else { return false }
    run = SmartListRunState(listID: list, anchorItemID: itemID, anchorEpisodeID: episodeID)
    if next.first?.episodeID == episodeID { next.removeFirst() }
    return true
  }

  func waitForRecordedStarts(_ count: Int) async {
    await starts.waitUntil(count: count)
  }
}
