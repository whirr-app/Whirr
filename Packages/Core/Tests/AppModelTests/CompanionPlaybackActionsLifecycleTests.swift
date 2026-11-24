import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Lifecycle races at the companion action boundary. These tests park the fake
/// `startSession` call so the account and request generations can change before preparation
/// returns. That is the window in which a stale companion command could otherwise load audio for
/// an account that has already logged out, or report success for a request the user replaced.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CompanionPlaybackActionsLifecycleTests {

  @Test("logout while preparation is suspended rejects the command and never loads it")
  func logoutWhileStartSessionIsSuspendedCannotInstallOldPlayback() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-a"))
    harness.sync.holdStartSession()

    let start = Task { @MainActor in
      await harness.actions.start(.init(source: selection))
    }
    await harness.sync.waitForCalls {
      $0.contains(.startSession(itemID: "book-a", episodeID: nil))
    }

    // Account logout and playback quiescence are separate boundaries. Exercise both before the
    // cancellation-insensitive fake replies, so an old operation must recheck the terminal state.
    harness.account.isAuthenticated = false
    await harness.playback.prepareForLogout()
    harness.sync.releaseStartSession(with: .success(Self.prepared(itemID: "book-a")))

    #expect(await start.value == .rejected(.accountUnavailable))
    #expect(harness.playback.isQuiescedForLogout)
    #expect(harness.playback.loadedItemID == nil)
    #expect(
      harness.player.intents.contains {
        if case .load = $0 { return true }
        return false
      } == false)
    #expect(harness.player.intents.contains(.play) == false)
  }

  @Test("a newer start makes the older preparation stale")
  func overlappingStartsRejectTheStaleReply() async throws {
    let harness = Self.makeHarness()
    let olderSelection = try #require(PodcastSourceIdentity.abs(itemId: "book-a"))
    let newerSelection = try #require(PodcastSourceIdentity.abs(itemId: "book-b"))
    harness.sync.holdStartSession()

    let older = Task { @MainActor in
      await harness.actions.start(.init(source: olderSelection))
    }
    await harness.sync.waitForCalls {
      $0.contains(.startSession(itemID: "book-a", episodeID: nil))
    }

    let newer = Task { @MainActor in
      await harness.actions.start(.init(source: newerSelection))
    }
    await waitUntil { harness.playback.activeItemID == "book-b" }

    // Complete the displaced request first. PlaybackModel closes its returned session and leaves
    // the newer operation queued, while CompanionPlaybackActions rejects its stale generation.
    harness.sync.releaseNextStartSession(with: .success(Self.prepared(itemID: "book-a")))
    #expect(await older.value == .rejected(.staleRequest))
    await harness.sync.waitForCalls {
      $0.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == 2
    }

    harness.sync.releaseStartSession(with: .success(Self.prepared(itemID: "book-b")))
    #expect(await newer.value == .accepted)
    #expect(harness.playback.isLoaded(itemID: "book-b", episodeID: nil))
    #expect(harness.playback.isLoaded(itemID: "book-a", episodeID: nil) == false)
  }

  @Test("cancelling a suspended start never reports accepted or installs playback")
  func cancelledStartedRequestIsClosedAfterTheReply() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-a"))
    harness.sync.holdStartSession()

    let start = Task { @MainActor in
      await harness.actions.start(.init(source: selection))
    }
    await harness.sync.waitForCalls {
      $0.contains(.startSession(itemID: "book-a", episodeID: nil))
    }

    start.cancel()
    // FakePlaybackSyncing keeps a parked start alive until the test releases it. This
    // proves cancellation is handled after a late preparation result, rather than relying on a
    // cancellation-aware network client to wake the operation.
    harness.sync.releaseStartSession(with: .success(Self.prepared(itemID: "book-a")))

    #expect(await start.value == .rejected(.cancelled))
    #expect(harness.playback.loadedItemID == nil)
    #expect(
      harness.player.intents.contains {
        if case .load = $0 { return true }
        return false
      } == false)
    #expect(harness.player.intents.contains(.play) == false)
    #expect(harness.sync.calls.contains(.stopSession))
  }

  @Test("pausing for a peer keeps the title loaded, reads the position first and never stops the session")
  func pauseForPeerKeepsTheTitleLoaded() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    harness.player.state.globalPosition = 42
    harness.player.isPlaybackIntended = true
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    let state = try #require(handoff.pauseForPeer())

    #expect(state.selection.itemID == "book-a")
    #expect(state.positionSeconds == 42)
    #expect(state.wasPlaying)
    #expect(harness.player.intents.last == .pause)
    #expect(harness.playback.isLoaded(itemID: "book-a", episodeID: nil))
    #expect(harness.sync.calls.contains(.stopSession) == false)
  }

  @Test("a title that was already paused is reported as not playing")
  func pauseForPeerReportsAPausedTitleAsNotPlaying() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    harness.player.isPlaybackIntended = false
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    let state = try #require(handoff.pauseForPeer())

    #expect(state.wasPlaying == false)
  }

  @Test("with nothing loaded there is nothing to pause or report")
  func pauseForPeerWithNothingLoaded() {
    let harness = Self.makeHarness()
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    #expect(handoff.pauseForPeer() == nil)
    #expect(handoff.peerState() == nil)
    #expect(harness.player.intents.contains(.pause) == false)
  }

  @Test("reading the peer state does not pause")
  func peerStateDoesNotPause() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)
    let before = harness.player.intents

    _ = handoff.peerState()

    #expect(harness.player.intents == before)
  }

  @Test("flushing progress after the pause closes the session and leaves the title resumable")
  func flushProgressClosesTheSession() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    _ = handoff.pauseForPeer()
    await handoff.flushProgress()

    #expect(harness.sync.calls.contains(.notifyImmediateSyncTrigger(.paused)))
    #expect(harness.sync.calls.contains(.stopSession))
    #expect(harness.actions.resume() == .accepted)
    await Self.waitForLoads(2, harness)
  }

  @Test("after pausing for a peer, the next phone play is a fresh start, not a resume of the stale position")
  func pauseForPeerMakesTheNextPlayAFreshStart() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    harness.player.state.globalPosition = 51
    var asked = 0
    harness.playback.authorizePlaybackStart = { _, _ in
      asked += 1
      return .allowed(position: 120)
    }
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    _ = handoff.pauseForPeer()
    await handoff.flushProgress()
    #expect(harness.playback.nextPlayStartsFresh(itemID: "book-a", episodeID: nil))
    harness.playback.togglePlayPause()

    await Self.waitForLoads(2, harness)
    #expect(asked == 1)
    #expect(Self.loadPositions(harness).last == 120)
    #expect(harness.playback.nextPlayStartsFresh(itemID: "book-a", episodeID: nil) == false)
  }

  @Test("a peer taking over the paused title closes the session and makes the next play a fresh start")
  func peerTookOverAPausedTitle() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    harness.player.state.globalPosition = 51
    harness.player.isPlaybackIntended = false
    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: nil) }
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a", startPosition: 120)))
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    #expect(await handoff.peerTookOver(itemID: "book-a", episodeID: nil))

    #expect(harness.sync.calls.contains(.notifyImmediateSyncTrigger(.paused)))
    #expect(harness.sync.calls.contains(.stopSession))
    #expect(harness.playback.nextPlayStartsFresh(itemID: "book-a", episodeID: nil))
    // A second report for the same takeover changes nothing more.
    let calls = harness.sync.calls.count
    #expect(await handoff.peerTookOver(itemID: "book-a", episodeID: nil) == false)
    #expect(harness.sync.calls.count == calls)

    harness.playback.togglePlayPause()
    await Self.waitForLoads(2, harness)
    #expect(Self.loadPositions(harness).last == 120)
  }

  @Test("a peer report does not take over a title the phone is playing, or one it has not loaded")
  func peerTookOverLeavesOtherCasesAlone() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-a")))
    await harness.playback.start(itemID: "book-a")
    let handoff = CompanionPlaybackHandoff(playback: harness.playback, actions: harness.actions)

    harness.player.isPlaybackIntended = true
    #expect(await handoff.peerTookOver(itemID: "book-a", episodeID: nil) == false)
    harness.player.isPlaybackIntended = false
    #expect(await handoff.peerTookOver(itemID: "book-b", episodeID: nil) == false)

    #expect(harness.sync.calls.contains(.stopSession) == false)
    #expect(harness.playback.nextPlayStartsFresh(itemID: "book-a", episodeID: nil) == false)
  }

  private static func loadPositions(_ harness: Harness) -> [Double] {
    harness.player.intents.compactMap {
      if case .load(_, let position, _, _) = $0 { return position } else { return nil }
    }
  }

  private static func waitForLoads(_ count: Int, _ harness: Harness) async {
    await waitUntil("\(count) loads") { loadPositions(harness).count >= count }
    #expect(loadPositions(harness).count == count)
  }

  private struct Harness {
    let actions: CompanionPlaybackActions
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let account: FakeAccountLifecycle
  }

  private static func makeHarness() -> Harness {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let playback = PlaybackModelHarness(account: account)
    let actions = CompanionPlaybackActions(
      playback: playback.model, player: playback.player, account: account)
    return Harness(
      actions: actions, playback: playback.model, player: playback.player, sync: playback.sync,
      account: account)
  }

  private static func prepared(
    itemID: String, episodeID: String? = nil, startPosition: Double = 0
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: startPosition, duration: 200,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 200,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg", title: itemID)
      ], chapters: [])
  }
}
