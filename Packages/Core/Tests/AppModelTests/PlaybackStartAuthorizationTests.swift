import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Playback starts must pass the composition-owned authorization gate before they create a
/// server session. The gate is also a logout boundary: a response that arrives after quiescence
/// may not reopen the account's player.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlaybackStartAuthorizationTests {

  @Test("a denied gate opens no session and sends no player intent")
  func deniedGateDoesNotStartPlayback() async throws {
    let harness = Self.makeHarness()
    harness.playback.authorizePlaybackStart = { _, _ in
      .denied(message: "another device owns playback")
    }

    await harness.playback.start(itemID: "book-gated")

    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(
      harness.player.intents.contains {
        if case .load = $0 { return true }
        return false
      } == false)
    #expect(harness.player.intents.contains(.play) == false)
    #expect(harness.playback.startFailureMessage == "another device owns playback")
  }

  @Test("an allowed gate position is handed to PlayerCore")
  func allowedPositionIsAppliedToLoad() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-position")))
    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: 42.5) }

    await harness.playback.start(itemID: "book-position")

    let loads = harness.player.intents.compactMap { intent -> Double? in
      if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
      return nil
    }
    #expect(loads == [42.5])
    #expect(harness.playback.isLoaded(itemID: "book-position", episodeID: nil))
  }

  @Test("a peer position seeks the title that is already loaded before resuming it")
  func peerPositionSeeksLoadedTitle() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-loaded")))
    await harness.playback.start(itemID: "book-loaded")
    harness.player.state.globalPosition = 10
    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: 40) }

    await harness.playback.start(itemID: "book-loaded")

    let tail = harness.player.intents.suffix(2)
    #expect(Array(tail) == [.seek(toGlobalOffset: 40), .play])
    #expect(Self.startCalls(harness.sync).count == 1)
  }

  @Test("no peer position, or one within a second, leaves the loaded title's position alone")
  func noPeerPositionDoesNotSeekLoadedTitle() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-loaded")))
    await harness.playback.start(itemID: "book-loaded")
    harness.player.state.globalPosition = 10
    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: nil) }
    await harness.playback.start(itemID: "book-loaded")
    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: 10.5) }
    await harness.playback.start(itemID: "book-loaded")

    let seeks = harness.player.intents.filter {
      if case .seek = $0 { return true }
      return false
    }
    #expect(seeks.isEmpty)
  }

  @Test("logout while the gate is suspended prevents the late authorization from opening playback")
  func delayedAuthorizationCannotCrossLogoutGeneration() async throws {
    let harness = Self.makeHarness()
    let gate = AuthorizationGate()
    harness.playback.authorizePlaybackStart = { _, _ in
      await gate.waitForAuthorization()
    }

    let start = Task { @MainActor in
      await harness.playback.start(itemID: "book-delayed")
    }
    await gate.waitUntilEntered()

    harness.account.isAuthenticated = false
    await harness.playback.prepareForLogout()
    await gate.release(.allowed(position: 9))
    await start.value

    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(harness.playback.loadedItemID == nil)
    #expect(
      harness.player.intents.contains {
        if case .load = $0 { return true }
        return false
      } == false)
    #expect(harness.player.intents.contains(.play) == false)
  }

  private struct Harness {
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let account: FakeAccountLifecycle
  }

  private static func makeHarness() -> Harness {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let playback = PlaybackModelHarness(account: account)
    return Harness(playback: playback.model, player: playback.player, sync: playback.sync, account: account)
  }

  private static func prepared(itemID: String) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg", title: itemID)
      ], chapters: [])
  }

  private static func startCalls(
    _ sync: FakePlaybackSyncing
  ) -> [FakePlaybackSyncing.RecordedCall] {
    sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
  }
}

private actor AuthorizationGate {
  // The authorization runs to completion regardless of cancellation, so logout cancelling the start
  // leaves it parked until the test releases it.
  private nonisolated let gate = TestGate<PlaybackStartAuthorization>(
    label: "AuthorizationGate authorization", ignoresCancellation: true)

  init() {
    gate.hold()
  }

  func waitForAuthorization() async -> PlaybackStartAuthorization {
    await gate.pass(otherwise: { .denied(message: "authorization gate expired") })
  }

  func waitUntilEntered() async {
    await gate.waitUntilParked()
  }

  func release(_ authorization: PlaybackStartAuthorization) {
    gate.releaseParked(authorization)
  }
}
