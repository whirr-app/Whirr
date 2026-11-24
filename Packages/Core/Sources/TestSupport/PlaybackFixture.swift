import Foundation
import SyncEngine

/// The `PreparedPlayback` shapes the playback suites hand to their fakes.
///
/// Suites keep passing their own URL, duration and track title, because those are the values under
/// test; the fixture only removes the repeated record wiring around them.
public enum PlaybackFixture {
  public static func prepared(
    itemID: String,
    episodeID: String? = nil,
    startPosition: Double = 0,
    duration: Double? = 100,
    tracks: [PreparedPlaybackTrack]? = nil,
    chapters: [PreparedPlaybackChapter] = [],
    source: PreparedPlaybackSource = .streaming,
    streamAuthorization: (any PlaybackStreamAuthorizationProviding)? = nil
  ) -> PreparedPlayback {
    PreparedPlayback(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: startPosition,
      duration: duration,
      tracks: tracks ?? [track(duration: duration ?? 100)],
      chapters: chapters,
      source: source,
      streamAuthorization: streamAuthorization)
  }

  public static func track(
    index: Int = 0,
    startOffset: Double = 0,
    duration: Double = 100,
    url: URL = URL(string: "https://example.test/track.mp3")!,
    mimeType: String? = "audio/mpeg",
    title: String? = nil
  ) -> PreparedPlaybackTrack {
    PreparedPlaybackTrack(
      index: index,
      startOffset: startOffset,
      duration: duration,
      url: url,
      mimeType: mimeType,
      title: title)
  }
}
