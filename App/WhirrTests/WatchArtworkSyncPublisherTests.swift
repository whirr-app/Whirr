import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
struct WatchArtworkSyncPublisherTests {
  let stamp = try! WatchAccountStamp(accountIdentityHash: "phone", serverIdentityHash: "s")
  let watchStamp = try! WatchAccountStamp(accountIdentityHash: "watch", serverIdentityHash: "s")
  let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)

  /// Records every file the publisher hands to WatchConnectivity, reading it before it can be deleted.
  final class FakeSender {
    var ready = true
    var sent: [(kind: String, data: Data, url: URL)] = []
    var cancelled: [URL] = []
    var sender: WatchArtworkSyncPublisher.Sender {
      WatchArtworkSyncPublisher.Sender(
        isReady: { [unowned self] in ready },
        transfer: { [unowned self] url, kind in
          sent.append((kind, (try? Data(contentsOf: url)) ?? Data(), url))
          return WatchArtworkTransferHandle(cancel: { [unowned self] in cancelled.append(url) })
        },
        outstanding: { [] })
    }
    func manifests() throws -> [WatchArtworkManifest] {
      try sent.filter { $0.kind == WatchArtworkSyncTransport.manifestKind }.map {
        try WatchWireCodec.decode(WatchArtworkManifest.self, from: $0.data)
      }
    }
    func bundles() throws -> [WatchArtworkBundle] {
      try sent.filter { $0.kind == WatchArtworkSyncTransport.bundleKind }.map {
        try WatchWireCodec.decode(WatchArtworkBundle.self, from: $0.data)
      }
    }
  }

  func outbox() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

  func publisher(
    _ fake: FakeSender, outbox: URL,
    load: @escaping @MainActor (WatchArtworkRequest) async -> Data? = { _ in Data([1]) }
  ) -> WatchArtworkSyncPublisher {
    WatchArtworkSyncPublisher(
      accountStamp: stamp, authenticatedStamp: watchStamp, load: load, sender: fake.sender, outbox: outbox,
      debounce: .zero)
  }

  func book(_ id: String, category: ItemMediaCategory = .audiobook, dated: Bool = true) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "book", title: id, author: nil, durationSeconds: nil, category: category,
      serverUpdatedAt: dated ? updatedAt : nil)
  }

  func rssShow(_ feedID: Int64) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: PodcastSourceIdentity.rss(feedId: feedID)!.itemId, mediaKind: "podcast", title: "Show",
      author: nil, durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://example.com/cover.jpg"),
      artworkFeedURL: URL(string: "https://example.com/feed.xml"))
  }

  func row(_ id: String, revision: String? = nil) -> WatchArtworkCover {
    WatchArtworkCover(
      reference: WatchArtworkReference(
        source: .audiobookshelf(itemID: id),
        revision: revision ?? WatchCatalogueWireMapper.artworkRevision(updatedAt)!),
      size: .row)
  }

  @Test func manifestListsContinueListeningPlayerCoversThenLibraryRowsThenFollowedShows() throws {
    let snapshot = try WatchCatalogueSnapshot(
      accountStamp: stamp,
      items: [
        WatchCatalogueItem(
          id: "cl", selection: .audiobookshelf(itemID: "b", episodeID: nil), title: "B",
          capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true),
          artworkRevision: "9")
      ])
    let covers = WatchArtworkSyncPublisher.covers(
      library: [book("a"), book("b"), book("ebook", category: .ebook), book("undated", dated: false)],
      followedShows: [rssShow(7), book("not-rss")], snapshot: snapshot)
    #expect(
      covers == [
        WatchArtworkCover(reference: .init(source: .audiobookshelf(itemID: "b"), revision: "9"), size: .player),
        row("a"), row("b"), row("undated", revision: WatchArtworkReference.unversioned),
        WatchArtworkCover(reference: .init(source: .nativeFeed(feedID: "7")), size: .row),
      ])
  }

  @Test func manifestWaitsForBothSourcesAndIsNotResentUnchanged() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = publisher(fake, outbox: root)
    publisher.update(library: [book("a")])
    await publisher.settle()
    #expect(fake.sent.isEmpty, "an empty followed-show list would prune every RSS cover")
    publisher.update(followedShows: [])
    await publisher.settle()
    let manifests = try fake.manifests()
    #expect(manifests.count == 1)
    #expect(manifests.first?.accountStamp == stamp)
    #expect(manifests.first?.authenticatedAccountStamp == watchStamp)
    #expect(manifests.first?.covers == [row("a")])

    publisher.update(library: [book("a")])
    await publisher.settle()
    #expect(fake.sent.count == 1)

    publisher.update(library: [book("a"), book("b")])
    await publisher.settle()
    #expect(try fake.manifests().count == 2)
    #expect(fake.cancelled == [fake.sent[0].url], "a newer manifest cancels the outstanding one")
  }

  @Test func anEmptyWantListResendsTheManifest() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = publisher(fake, outbox: root)
    publisher.update(library: [book("a")])
    publisher.update(followedShows: [])
    await publisher.settle()
    publisher.receive(try WatchArtworkWantList(accountStamp: stamp, manifestID: nil, covers: []))
    await publisher.settle()
    #expect(try fake.manifests().count == 2)
  }

  @Test func nothingIsSentWhileTheWatchAppIsUnavailable() async throws {
    let fake = FakeSender()
    fake.ready = false
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = publisher(fake, outbox: root)
    publisher.update(library: [book("a")])
    publisher.update(followedShows: [])
    await publisher.settle()
    #expect(fake.sent.isEmpty)
    fake.ready = true
    publisher.watchBecameAvailable()
    await publisher.settle()
    #expect(try fake.manifests().count == 1)
  }

  @Test func aWantListIsAnsweredWithBundlesAndAFinalListOfWhatFailed() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    var requested: [WatchArtworkRequest] = []
    let publisher = publisher(fake, outbox: root) { request in
      requested.append(request)
      guard case .audiobookshelf(let id) = request.reference.source, id != "broken" else { return nil }
      return Data(repeating: 1, count: 40 * 1024)
    }
    let covers = (0..<30).map { row("b\($0)") } + [row("broken")]
    let wantList = try WatchArtworkWantList(accountStamp: stamp, manifestID: UUID(), covers: covers)
    publisher.receive(wantList)
    await publisher.settle()

    #expect(requested.count == 31)
    #expect(requested.allSatisfy { $0.accountStamp == stamp && $0.size == .row })
    let bundles = try fake.bundles()
    #expect(bundles.count == 2, "30 covers of 40 KB exceed one 1 MB bundle")
    #expect(bundles.allSatisfy { $0.wantListID == wantList.id })
    #expect(bundles.map(\.isFinal) == [false, true])
    #expect(bundles.flatMap(\.entries).map(\.cover) == Array(covers.prefix(30)))
    #expect(bundles.last?.unavailable == [row("broken")])
  }

  @Test func aWantListForAnotherAccountIsIgnored() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    var loads = 0
    let publisher = publisher(fake, outbox: root) { _ in
      loads += 1
      return Data([1])
    }
    publisher.receive(try WatchArtworkWantList(accountStamp: watchStamp, manifestID: nil, covers: [row("a")]))
    await publisher.settle()
    #expect(loads == 0)
    #expect(fake.sent.isEmpty)
  }

  @Test func stopCancelsTransfersAndDeletesTheirFiles() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = publisher(fake, outbox: root)
    publisher.update(library: [book("a")])
    publisher.update(followedShows: [])
    await publisher.settle()
    let url = try #require(fake.sent.first?.url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    publisher.stop()
    #expect(fake.cancelled == [url])
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func aFinishedTransferDeletesItsFile() async throws {
    let fake = FakeSender()
    let root = outbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let publisher = publisher(fake, outbox: root)
    publisher.update(library: [book("a")])
    publisher.update(followedShows: [])
    await publisher.settle()
    let url = try #require(fake.sent.first?.url)
    publisher.transferFinished(url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    publisher.stop()
    #expect(fake.cancelled.isEmpty)
  }
}
