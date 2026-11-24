import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite("Native podcast unfollow action")
struct NativePodcastUnfollowActionTests {
  @Test("matching playback stops before the feed is deleted")
  func stopPrecedesDeletion() async throws {
    let events = CallRecorder<UnfollowEvent>(label: "unfollow events")
    let action = makeAction(events: events)

    try await action.unfollow(itemID: "rss:7")

    #expect(events.calls == [.stop("rss:7"), .unsubscribe(7)])
  }

  @Test("a playback-stop failure is classified and aborts deletion")
  func stopFailureAbortsDeletion() async {
    let events = CallRecorder<UnfollowEvent>(label: "unfollow events")
    let action = makeAction(events: events, stopFails: true)

    await #expect(throws: NativePodcastUnfollowError.playbackStopFailed) {
      try await action.unfollow(itemID: "rss:7")
    }
    #expect(events.calls == [.stop("rss:7")])
  }

  @Test("a feed deletion failure is classified after playback has stopped")
  func deletionFailureIsClassified() async {
    let events = CallRecorder<UnfollowEvent>(label: "unfollow events")
    let action = makeAction(events: events, unsubscribeFails: true)

    await #expect(throws: NativePodcastUnfollowError.unsubscribeFailed) {
      try await action.unfollow(itemID: "rss:7")
    }
    #expect(events.calls == [.stop("rss:7"), .unsubscribe(7)])
  }

  @Test("a server identity cannot reach playback or feed deletion")
  func serverIdentityIsRejected() async {
    let events = CallRecorder<UnfollowEvent>(label: "unfollow events")
    let action = makeAction(events: events)

    await #expect(throws: NativePodcastUnfollowError.notNativePodcast) {
      try await action.unfollow(itemID: "server-show")
    }
    #expect(events.calls.isEmpty)
  }
}

private enum NativeUnfollowTestError: Error { case failed }

private enum UnfollowEvent: Sendable, Equatable {
  case stop(String)
  case unsubscribe(Int64)
}

/// An unfollow action over the shared feed-managing fake, with playback stop and unsubscribe
/// writing to one ordered log.
private func makeAction(
  events: CallRecorder<UnfollowEvent>, stopFails: Bool = false, unsubscribeFails: Bool = false
) -> NativePodcastUnfollowAction {
  let feeds = FakeNativeFeedManaging()
  if unsubscribeFails { feeds.stubUnsubscribeFailure(NativeUnfollowTestError.failed) }
  feeds.setUnsubscribeHook { events.record(.unsubscribe($0)) }
  return NativePodcastUnfollowAction(
    feedManaging: feeds,
    stopPlayback: {
      events.record(.stop($0))
      if stopFails { throw NativeUnfollowTestError.failed }
    })
}
