import Foundation
import PlayerCore
import Testing

@testable import WatchPlayback

/// A track carries the Bearer header its download needs, so no textual form may print it
/// (SECURITY.md rule 7), whether the track is reflected alone or inside a preparation.
@Suite struct WatchAudioTrackRedactionTests {
  private static let secret = "Bearer watch-access-secret"

  private static let track = WatchAudioTrack(
    index: 3, url: URL(string: "https://books.example.test/api/items/li_1/file/7")!,
    headers: ["Authorization": secret])

  @Test("a track never prints its headers")
  func trackRedactsHeaders() {
    var dumped = ""
    dump(Self.track, to: &dumped)
    for text in [
      String(describing: Self.track), String(reflecting: Self.track), "\(Self.track)", dumped,
    ] {
      #expect(text.contains("watch-access-secret") == false, "\(text)")
      #expect(text.contains("Authorization") == false, "\(text)")
    }
  }

  @Test("a preparation never prints its tracks' headers")
  func preparationRedactsTrackHeaders() throws {
    let preparation = WatchAudioPreparation(
      title: "Book",
      timeline: try PlaybackTimeline(tracks: [PlaybackTrack(index: 3, startOffset: 0, duration: 60)]),
      tracks: [Self.track])
    var dumped = ""
    dump(preparation, to: &dumped)
    for text in [String(describing: preparation), String(reflecting: preparation), dumped] {
      #expect(text.contains("watch-access-secret") == false, "\(text)")
    }
  }
}
