import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

struct PlaybackAvailabilityTests {
  private static let since = Date(timeIntervalSince1970: 123)
  private static let unreachable = ServerReachability.unreachable(
    .serverUnreachable, since: Self.since)

  @Test func stalledStreamingPlaybackIsUnavailable() {
    for reachability in Self.reachabilities {
      #expect(
        PlaybackAvailability.remotePlaybackUnavailable(
          phase: .stalled, isStreamingSource: true, reachability: reachability))
    }
  }

  @Test func bufferingStreamingPlaybackIsUnavailableWhenTheServerIsUnreachable() {
    #expect(
      PlaybackAvailability.remotePlaybackUnavailable(
        phase: .buffering, isStreamingSource: true, reachability: Self.unreachable))
  }

  @Test func bufferingStreamingPlaybackIsNotUnavailableBeforeReachabilityHasAnswered() {
    #expect(
      PlaybackAvailability.remotePlaybackUnavailable(
        phase: .buffering, isStreamingSource: true, reachability: .unknown) == false)
  }

  @Test func bufferingStreamingPlaybackIsAvailableWhenTheServerIsReachable() {
    #expect(
      PlaybackAvailability.remotePlaybackUnavailable(
        phase: .buffering, isStreamingSource: true, reachability: .reachable) == false)
  }

  @Test func everyPhaseIsAvailableForANonStreamingSource() {
    for phase in Self.allPhases {
      for reachability in Self.reachabilities {
        #expect(
          PlaybackAvailability.remotePlaybackUnavailable(
            phase: phase, isStreamingSource: false, reachability: reachability) == false)
      }
    }
  }

  @Test func everyOtherPhaseIsAvailableRegardlessOfReachability() {
    for phase in Self.nonUnavailablePhases {
      for reachability in Self.reachabilities {
        #expect(
          PlaybackAvailability.remotePlaybackUnavailable(
            phase: phase, isStreamingSource: true, reachability: reachability) == false)
      }
    }
  }

  @Test func rssBufferingIgnoresABSReachability() throws {
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId

    #expect(
      PlaybackAvailability.remotePlaybackUnavailable(
        phase: .buffering, isStreamingSource: true, reachability: Self.unreachable,
        itemID: rssItemID) == false)
    #expect(
      PlaybackAvailability.unavailableReason(
        phase: .buffering, isStreamingSource: true, reachability: Self.unreachable,
        itemID: rssItemID) == nil)
  }

  @Test func rssStallRemainsRecoverableButHasNoABSOutageReason() throws {
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId

    #expect(
      PlaybackAvailability.remotePlaybackUnavailable(
        phase: .stalled, isStreamingSource: true, reachability: .unknown,
        itemID: rssItemID))
    #expect(
      PlaybackAvailability.unavailableReason(
        phase: .stalled, isStreamingSource: true, reachability: .unknown,
        itemID: rssItemID) == nil)
  }

  @Test func malformedReservedIdentityDoesNotCrossIntoABSAvailability() {
    #expect(
      PlaybackAvailability.unavailableReason(
        phase: .stalled, isStreamingSource: true, reachability: .unknown,
        itemID: "rss:not-a-feed") == nil)
  }

  private static let reachabilities: [ServerReachability] = [
    .unknown,
    .reachable,
    Self.unreachable,
  ]

  private static let allPhases: [PlaybackModel.Phase] = [
    .idle,
    .preparing,
    .buffering,
    .stalled,
    .playing,
    .paused,
    .seeking,
    .recoverableError,
    .unrecoverableError,
    .ended,
  ]

  private static let nonUnavailablePhases: [PlaybackModel.Phase] = [
    .playing,
    .paused,
    .preparing,
    .seeking,
    .ended,
    .idle,
    .recoverableError,
    .unrecoverableError,
  ]
}
