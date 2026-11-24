import Foundation
import Testing

@testable import WatchPlayback

/// An authorized Watch track is admitted only when its URL has the account server's exact origin,
/// carries no userinfo, and names the ABS file route. The predicate is fail-closed on a missing
/// host, so two hostless URLs cannot collide into one empty origin.
@Suite struct WatchAudioPreparationOriginTests {
  private static let server = URL(string: "https://books.example.test")!

  private static func admits(_ url: String, server: URL = server) -> Bool {
    WatchAudioPreparationFactory.admitsTrackURL(URL(string: url)!, serverURL: server)
  }

  @Test("the server's own file route is admitted")
  func admitsSameOriginFileRoute() {
    #expect(Self.admits("https://books.example.test/api/items/li_1/file/7"))
  }

  @Test("two hostless URLs do not collide into one empty origin")
  func rejectsHostlessPair() {
    #expect(
      Self.admits(
        "https:///api/items/li_1/file/7", server: URL(string: "https:///abs")!) == false)
  }

  @Test("a different port is a different origin")
  func rejectsDifferentPort() {
    #expect(Self.admits("https://books.example.test:8443/api/items/li_1/file/7") == false)
  }

  @Test("an explicit default port is the same origin as an implicit one")
  func admitsExplicitDefaultPort() {
    #expect(Self.admits("https://books.example.test:443/api/items/li_1/file/7"))
    #expect(
      Self.admits(
        "https://books.example.test/api/items/li_1/file/7",
        server: URL(string: "https://books.example.test:443")!))
  }

  @Test("userinfo on the track URL is refused even on the server's origin")
  func rejectsUserinfo() {
    #expect(Self.admits("https://watch:secret@books.example.test/api/items/li_1/file/7") == false)
  }

  @Test("a same-origin URL outside the file route is refused")
  func rejectsOtherRoutes() {
    #expect(Self.admits("https://books.example.test/api/items/li_1/ebook") == false)
  }
}
