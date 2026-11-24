import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Podcast current-server fixture (2.36.0)")
struct PodcastCurrentServerFixtureTests {

  @Test("decodes profile type, activity, and mutation permissions for every captured profile")
  func decodesCurrentServerProfiles() async throws {
    let cases: [(String, String, String, Bool, Bool, Bool)] = [
      (
        "current-server-2-36-0-me-admin-default", "<user-admin_default>", "admin", true, true, false
      ),
      ("current-server-2-36-0-me-admin-delete", "<user-admin_delete>", "admin", true, true, true),
      ("current-server-2-36-0-me-root", "<user-root>", "root", true, true, true),
      (
        "current-server-2-36-0-me-user-ordinary", "<user-user_ordinary>", "user", true, false, false
      ),
    ]

    for (fixture, id, type, isActive, canUpdate, canDelete) in cases {
      let (client, _, account) = try makeCurrentServerFixtureClient(named: fixture)
      let profile = try await client.fetchUserProfile(account: account)

      #expect(profile.id == id)
      #expect(profile.type == type)
      #expect(profile.isActive == isActive)
      #expect(profile.permissionsUpdate == canUpdate)
      #expect(profile.permissionsDelete == canDelete)
    }
  }

  @Test("projects the current server's podcast library and folder")
  func decodesCurrentServerLibraryProjection() async throws {
    let (client, _, account) = try makeCurrentServerFixtureClient(
      named: "current-server-2-36-0-libraries-root")

    let libraries = try await client.listLibraries(account: account)

    let library = try #require(libraries.first)
    #expect(library.id == "<library-a>")
    #expect(library.name == "NP12 Podcasts")
    #expect(library.mediaType == "podcast")
    let folder = try #require(library.folders.first)
    #expect(folder.id == "<folder-a>")
    #expect(folder.fullPath == "/podcasts")
    #expect(folder.libraryID == "<library-a>")
  }

  @Test("decodes the current server's minified podcast feed URL")
  func decodesCurrentServerMinifiedFeedURL() async throws {
    let (client, _, account) = try makeCurrentServerFixtureClient(
      named: "current-server-2-36-0-items-minified-after-create")

    let page = try await client.listLibraryItems(account: account, library: "library-a")

    #expect(page.items.count == 3)
    #expect(
      page.items.map(\.feedURLState) == [
        .value("http://<feed-host>/feed/basic.xml"),
        .value("http://<feed-host>/feed/basic.xml"),
        .value("http://<feed-host>/feed/basic.xml"),
      ])
    // The captured shows declare no language: the key is present and null, which is a statement
    // that the show is untagged, not an omission.
    #expect(page.items.map(\.podcastLanguageState) == [.cleared, .cleared, .cleared])
  }

  @Test("accepts the current server's create response as a usable item")
  func decodesCurrentServerCreateResponseID() async throws {
    let (client, _, account) = try makeCurrentServerFixtureClient(
      named: "current-server-2-36-0-create-valid-admin-default")

    let itemID = try await client.createPodcast(
      account: account,
      libraryID: "library-a",
      folderID: "folder-a",
      path: "/podcasts/basic",
      title: "NP12 Basic Show",
      author: "NP12 Spike",
      feedURL: "http://feed.example/feed/basic.xml"
    )

    #expect(itemID == "f9603d64-7a39-467e-94b5-731d70fc8ba9")
  }

  @Test("decodes the current server's empty expanded show as structurally complete")
  func decodesCurrentServerEmptyExpandedShow() async throws {
    let (client, _, account) = try makeCurrentServerFixtureClient(
      named: "current-server-2-36-0-item-expanded-empty-show")

    let detail = try await client.fetchItemDetail(account: account, itemID: "show-a")

    #expect(detail.id == "<show-a>")
    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.episodes.isEmpty)
    #expect(podcast.isEpisodeListStructurallyComplete)
  }
}

private func makeCurrentServerFixtureClient(
  named name: String
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let store = InMemoryTokenStore()
  try store.save(
    TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
    for: account
  )
  let http = FakeHTTPClient(
    responses: [
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try Fixtures.data(named: name)
      )
    ]
  )
  return (ABSClient(server: server, httpClient: http, tokenStore: store), http, account)
}
