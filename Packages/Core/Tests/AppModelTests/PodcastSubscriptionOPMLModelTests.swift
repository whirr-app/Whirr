import Foundation
import Persistence
import PodcastFeeds
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Podcast subscription OPML model", .timeLimit(.minutes(1)))
struct PodcastSubscriptionOPMLModelTests {
  @Test("parses a checkbox preview and deduplicates repeated feed URLs")
  func importPreview() async {
    let model = Self.model()
    await model.loadImport(
      data: Data(
        """
        <opml><body>
          <outline text="One" xmlUrl="https://feeds.example/one.xml"/>
          <outline text="Duplicate" xmlUrl="https://feeds.example/one.xml"/>
          <outline xmlUrl="https://feeds.example/two.xml"/>
        </body></opml>
        """.utf8))

    #expect(model.rows.count == 2)
    #expect(model.rows.map(\.isSelected) == [true, true])
    #expect(model.rows[0].title == "One")
    #expect(model.selectedCount == 2)
    model.setSelected(false, rowID: model.rows[1].id)
    #expect(model.selectedCount == 1)
  }

  @Test("bulk follow preserves successes while reporting each failed feed")
  func partialFailure() async {
    let good = URL(string: "https://feeds.example/good.xml")!
    let bad = URL(string: "https://feeds.example/bad.xml")!
    let previews = FakeFeedPreviewProviding()
    previews.stubResult(.failure(.notAFeed), for: bad)
    let following = OPMLFollowing()
    let model = PodcastSubscriptionOPMLModel(previews: previews, following: following)
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"Good\" xmlUrl=\"\(good)\"/><outline text=\"Bad\" xmlUrl=\"\(bad)\"/></body></opml>"
          .utf8))

    await model.followSelected()

    #expect(model.rows.contains { if case .followed = $0.status { true } else { false } })
    #expect(model.rows.contains { $0.status == .failed(.notAFeed) })
    #expect(await following.followedURLs == [good])
  }

  @Test("a fully committed import offers a way out instead of a permanently disabled follow")
  func commitStateReachesDone() async {
    let good = URL(string: "https://feeds.example/good.xml")!
    let bad = URL(string: "https://feeds.example/bad.xml")!
    let previews = FakeFeedPreviewProviding()
    previews.stubResult(.failure(.notAFeed), for: bad)
    let model = PodcastSubscriptionOPMLModel(previews: previews, following: OPMLFollowing())
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"Good\" xmlUrl=\"\(good)\"/><outline text=\"Bad\" xmlUrl=\"\(bad)\"/></body></opml>"
          .utf8))

    #expect(model.commitState == .follow(count: 2))
    model.setSelected(false, rowID: model.rows[1].id)
    #expect(model.commitState == .follow(count: 1))
    model.setSelected(true, rowID: model.rows[1].id)

    await model.followSelected()

    // A failed row is terminal too: it cannot be reselected, so leaving is all that remains.
    #expect(model.commitState == .done)
  }

  @Test("an empty preview has nothing to commit and nothing to leave")
  func commitStateWithoutRows() {
    let model = Self.model()

    #expect(model.commitState == .follow(count: 0))
  }

  @Test("export serializes every device-owned subscription to a temporary OPML file")
  func export() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    _ = try await store.subscribe(
      feedURL: URL(string: "https://feeds.example/one.xml")!, title: "One", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(),
      exporter: RSSSubscriptionOPMLExporter(store: store))

    await model.prepareExport(in: directory)

    let url = try #require(model.exportURL)
    #expect(url.pathExtension == "opml")
    let document = try OPML.parse(Data(contentsOf: url))
    #expect(document.entries.map(\.feedURL) == [URL(string: "https://feeds.example/one.xml")!])
  }

  @Test("a successful export file is removed when its model is released")
  func successfulExportIsCleanedUpAtTheModelLifetimeBoundary() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var model: PodcastSubscriptionOPMLModel? = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing())

    await model?.prepareExport(in: directory)
    let url = try #require(model?.exportURL)
    #expect(FileManager.default.fileExists(atPath: url.path))

    model = nil

    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  @Test("an export failure removes the previously shared temporary file")
  func failedReplacementExportCleansUpThePreviousFile() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exporter = ScriptedOPMLExporter(steps: [.success, .failure])
    let model = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(), exporter: exporter)

    await model.prepareExport(in: directory)
    let previousURL = try #require(model.exportURL)
    #expect(FileManager.default.fileExists(atPath: previousURL.path))

    await model.prepareExport(in: directory)

    #expect(model.exportURL == nil)
    #expect(model.exportError)
    #expect(FileManager.default.fileExists(atPath: previousURL.path) == false)
  }

  @Test("a transient unlink failure remains owned for model lifetime cleanup")
  func transientUnlinkFailureIsRetriedAtTheModelLifetimeBoundary() async throws {
    let directory = Self.temporaryDirectory()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    let exporter = ScriptedOPMLExporter(steps: [.success, .failure])
    var model: PodcastSubscriptionOPMLModel? = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(), exporter: exporter)
    await model?.prepareExport(in: directory)
    let previousURL = try #require(model?.exportURL)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    await model?.prepareExport(in: directory)
    #expect(FileManager.default.fileExists(atPath: previousURL.path))

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    model = nil

    #expect(FileManager.default.fileExists(atPath: previousURL.path) == false)
  }

  @Test("a cancelled replacement export cannot strand the previous temporary file")
  func cancelledReplacementExportCleansUpThePreviousFile() async throws {
    let directory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let exporter = ScriptedOPMLExporter(steps: [.success, .heldSuccess])
    let model = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(), exporter: exporter)
    await model.prepareExport(in: directory)
    let previousURL = try #require(model.exportURL)

    let replacement = Task { await model.prepareExport(in: directory) }
    await exporter.waitUntilHeld()
    replacement.cancel()
    await exporter.release()
    await replacement.value

    #expect(model.exportURL == nil)
    #expect(model.exportError)
    #expect(FileManager.default.fileExists(atPath: previousURL.path) == false)
  }

  @Test("cancelling bulk follow restores the current and unattempted rows to pending")
  func cancellation() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = PodcastSubscriptionOPMLModel(previews: previews, following: OPMLFollowing())
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"One\" xmlUrl=\"https://feeds.example/one.xml\"/><outline text=\"Two\" xmlUrl=\"https://feeds.example/two.xml\"/></body></opml>"
          .utf8))

    let followTask = Task { await model.followSelected() }
    await previews.waitForRequestCount(1)
    followTask.cancel()
    previews.releaseAll()
    await followTask.value

    #expect(model.rows.map(\.status) == [.pending, .pending])
    #expect(model.isFollowing == false)
  }

  @Test("a replacement import cannot receive a completed follow from the old rows")
  func replacementDuringFollowDoesNotMutateNewImport() async throws {
    let oldURL = URL(string: "https://feeds.example/old.xml")!
    let newURL = URL(string: "https://feeds.example/new.xml")!
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = PodcastSubscriptionOPMLModel(previews: previews, following: OPMLFollowing())
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"Old\" xmlUrl=\"\(oldURL)\"/></body></opml>".utf8))
    let oldRowID = try #require(model.rows.first?.id)

    let followTask = Task { await model.followSelected() }
    await previews.waitForRequestCount(1)
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"New\" xmlUrl=\"\(newURL)\"/></body></opml>".utf8))
    let newRowID = try #require(model.rows.first?.id)

    previews.releaseAll()
    await followTask.value

    #expect(newRowID != oldRowID)
    #expect(model.rows.first?.feedURL == newURL)
    #expect(model.rows.first?.status == .pending)
  }

  @Test("reset during a follow leaves an empty preview without crashing")
  func resetDuringFollowLeavesNoRows() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = PodcastSubscriptionOPMLModel(previews: previews, following: OPMLFollowing())
    await model.loadImport(
      data: Data(
        "<opml><body><outline text=\"One\" xmlUrl=\"https://feeds.example/one.xml\"/></body></opml>"
          .utf8))

    let followTask = Task { await model.followSelected() }
    await previews.waitForRequestCount(1)
    model.resetImport()
    previews.releaseAll()
    await followTask.value

    #expect(model.rows.isEmpty)
    #expect(model.isFollowing == false)
  }

  @Test("an older held parse cannot replace a newer completed import")
  func staleParseCannotOverwriteNewerImport() async {
    let parser = HeldOPMLParser()
    let model = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(),
      parsing: { try await parser.parse($0) })
    let oldURL = URL(string: "https://feeds.example/old.xml")!
    let newURL = URL(string: "https://feeds.example/new.xml")!

    let oldLoad = Task { await model.loadImport(data: Data("old".utf8)) }
    await parser.waitForRequestCount(1)
    let newLoad = Task { await model.loadImport(data: Data("new".utf8)) }
    await parser.waitForRequestCount(2)
    await parser.complete(request: 1, with: Self.document(title: "New", feedURL: newURL))
    await newLoad.value
    #expect(model.rows.map(\.feedURL) == [newURL])

    await parser.complete(request: 0, with: Self.document(title: "Old", feedURL: oldURL))
    await oldLoad.value

    #expect(model.rows.map(\.feedURL) == [newURL])
    #expect(model.rows.map(\.title) == ["New"])
    #expect(model.importFailure == nil)
  }

  @Test("a held parse completing after reset leaves the import empty")
  func staleParseCannotOverwriteReset() async {
    let parser = HeldOPMLParser()
    let model = PodcastSubscriptionOPMLModel(
      previews: FakeFeedPreviewProviding(), following: OPMLFollowing(),
      parsing: { try await parser.parse($0) })
    let load = Task { await model.loadImport(data: Data("held".utf8)) }
    await parser.waitForRequestCount(1)

    model.resetImport()
    await parser.complete(
      request: 0,
      with: Self.document(
        title: "Held", feedURL: URL(string: "https://feeds.example/held.xml")!))
    await load.value

    #expect(model.rows.isEmpty)
    #expect(model.importFailure == nil)
  }

  private static func model() -> PodcastSubscriptionOPMLModel {
    PodcastSubscriptionOPMLModel(previews: FakeFeedPreviewProviding(), following: OPMLFollowing())
  }

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private static func document(title: String, feedURL: URL) -> OPMLDocument {
    OPMLDocument(
      title: nil,
      entries: [OPMLFeedEntry(title: title, feedURL: feedURL, siteURL: nil)])
  }
}

private enum OPMLExportTestError: Error {
  case failed
}

private actor ScriptedOPMLExporter: NativeSubscriptionOPMLExporting {
  enum Step: Sendable {
    case success
    case failure
    case heldSuccess
  }

  private var steps: [Step]
  // A held export stays parked through task cancellation until `release()`.
  private nonisolated let gate = TestGate<Void>(
    label: "ScriptedOPMLExporter held export", ignoresCancellation: true)

  init(steps: [Step]) { self.steps = steps }

  func exportOPML() async throws -> Data {
    guard steps.isEmpty == false else { throw OPMLExportTestError.failed }
    switch steps.removeFirst() {
    case .success:
      return Self.data
    case .failure:
      throw OPMLExportTestError.failed
    case .heldSuccess:
      gate.hold()
      await gate.pass()
      return Self.data
    }
  }

  func waitUntilHeld() async {
    await gate.waitUntilParked()
  }

  func release() {
    gate.release()
  }

  private static let data = Data("<opml><body></body></opml>".utf8)
}

private actor HeldOPMLParser {
  private typealias ParseGate = TestGate<Result<OPMLDocument, any Error>>
  private var nextRequest = 0
  private var gates: [Int: ParseGate] = [:]
  private let requests = TestCountRecorder(label: "HeldOPMLParser parses")

  func parse(_ data: Data) async throws -> OPMLDocument {
    let request = nextRequest
    nextRequest += 1
    let gate = gate(for: request)
    gate.hold()
    requests.record()
    return try await gate.pass(otherwise: { .failure(CancellationError()) }).get()
  }

  func waitForRequestCount(_ count: Int) async {
    await requests.waitUntil(count: count)
  }

  /// Waits for the parse to park first: it counts its request just before it parks.
  func complete(request: Int, with document: OPMLDocument) async {
    let gate = gate(for: request)
    await gate.waitUntilParked()
    gate.releaseNext(.success(document))
  }

  // A held parse stays parked through task cancellation until completed.
  private func gate(for request: Int) -> ParseGate {
    if let gate = gates[request] { return gate }
    let gate = ParseGate(
      label: "HeldOPMLParser parse \(request)", ignoresCancellation: true)
    gates[request] = gate
    return gate
  }
}

private actor OPMLFollowing: NativeFeedFollowing {
  private(set) var followedURLs: [URL] = []
  func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    followedURLs.append(preview.feedURL)
    return Int64(followedURLs.count)
  }
}
