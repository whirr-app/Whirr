import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The one client allowed to issue unauthenticated cover GETs (see ARCHITECTURE.md and
/// API-CONVENTIONS.md). Every test drives a `BlockingHTTPClient` fake directly (the gated-fake
/// pattern of `CompositionTransport` in `ABSClientCompositionTests.swift`) so completion order is
/// deterministic and no test needs a sleep.
@Suite("CoverImageClient")
struct CoverImageClientTests {

  @Test("prepared artwork identity uses the explicitly composed account scope")
  func usesExplicitArtworkAccountScope() throws {
    let scope = ArtworkAccountScope("https://books.example.test#account=42")
    let client = CoverImageClient(
      server: try makeServer(),
      httpClient: BlockingHTTPClient(),
      artworkScope: scope)

    #expect(client.artworkScope == scope)
  }

  @Test("clients over one directory share one store")
  func clientsOverOneDirectoryShareOneStore() async throws {
    let directory = try makeTemporaryDirectory("shared")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let request = try CoverRequest(itemID: "item-1", width: 132)
    try await populateDiskCache(
      directory: directory, server: server, request: request, body: Data("shared".utf8))
    let first = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      cacheDirectory: directory)
    let second = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      cacheDirectory: directory)
    #expect(await second.data(for: request) == Data("shared".utf8))

    // A clear through one client is a clear for the other: there is one store, not two views.
    await first.clearCachedArtwork()
    #expect(await second.data(for: request) == nil)
    #expect(CoverFileStore.shared(root: directory) === CoverFileStore.shared(root: directory))
  }

  @Test("a client with no directory keeps covers in memory and shares them with no other client")
  func defaultConstructionIsMemoryOnlyAndIsolated() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let first = CoverImageClient(server: server, httpClient: transport)
    let second = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()))
    let request = try CoverRequest(itemID: "item-1", width: 132)

    let fetch = Task { try await first.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data("mine".utf8)))
    _ = try await fetch.value

    #expect(await first.data(for: request) == Data("mine".utf8))
    #expect(await second.data(for: request) == nil)
  }

  @Test("a memory-only client with no capacity stores nothing")
  func zeroMemoryCapacityStoresNothing() async throws {
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport, memoryCapacity: 0)
    let request = try CoverRequest(itemID: "item-1", width: 132)

    let fetch = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data("bytes".utf8)))
    _ = try await fetch.value

    #expect(await client.data(for: request) == nil)
  }

  @Test("N concurrent requests for the same cover produce exactly one transport request")
  func coalescesConcurrentRequestsForSameCover() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 400)

    let tasks = (0..<5).map { _ in Task { try await client.fetch(request) } }
    try await waitUntil { await transport.requests.count == 1 }
    #expect(await transport.requests.count == 1)

    let responseBody = Data("cover-bytes".utf8)
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: responseBody)
    )

    for task in tasks {
      let result = try await task.value
      #expect(result.data == responseBody)
      #expect(result.contentType == "image/webp")
    }
    // Still exactly one transport request: the other four coalesced onto it.
    #expect(await transport.requests.count == 1)
  }

  @Test("at most six distinct covers are in flight at once; a seventh queues FIFO")
  func capsInFlightAtSixWithFIFOAdmission() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let requests = try (0..<7).map { try CoverRequest(itemID: "item-\($0)") }

    let tasks = requests.map { request in Task { try await client.fetch(request) } }

    try await waitUntil { await transport.requests.count == 6 }
    #expect(await transport.requests.count == 6)
    #expect(await transport.maxInFlight == 6)

    let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data())
    await transport.releaseOldest(with: response)
    try await waitUntil { await transport.requests.count == 7 }
    #expect(await transport.requests.count == 7)
    #expect(await transport.maxInFlight == 6)

    await transport.releaseAll(with: response)
    for task in tasks {
      _ = try await task.value
    }
  }

  @Test("cover requests carry no Authorization header and no token anywhere in the URL")
  func noAuthHeaderOrTokenInURL() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 200)

    let task = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data())
    )
    _ = try await task.value

    let sent = await transport.requests
    #expect(sent.count == 1)
    #expect(sent[0].headers["Authorization"] == nil)
    #expect(sent[0].url.absoluteString.contains("token") == false)
    #expect(sent[0].maximumResponseBytes == CoverImageLimits.maximumResponseBytes)
  }

  @Test("cover requests carry server custom headers")
  func carriesServerCustomHeaders() async throws {
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")),
      customHeaders: try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    )
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 200)

    let task = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    #expect((await transport.requests)[0].headers["X-Proxy-Token"] == "proxy-secret")
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data())
    )
    _ = try await task.value
  }

  @Test("cover responses with a non-image MIME type are rejected and not cached")
  func rejectsNonImageResponseBeforeCaching() async throws {
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 200)
    let task = Task { try await client.fetch(request) }

    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))

    await #expect(throws: APIError.decoding) { try await task.value }
    #expect(await client.data(for: request) == nil)
  }

  @Test("cover responses over 20 MiB are rejected and not cached")
  func rejectsOversizedResponseBeforeCaching() async throws {
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 200)
    let task = Task { try await client.fetch(request) }

    try await waitUntil { await transport.requests.count == 1 }
    let oversized = Data(repeating: 0, count: CoverImageLimits.maximumResponseBytes + 1)
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: oversized))

    await #expect(throws: APIError.payloadTooLarge) { try await task.value }
    #expect(await client.data(for: request) == nil)
  }

  @Test("width and format reach the transport untouched, taken only from the (already-quantized) request value")
  func widthAndFormatPassThroughUntouched() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    // 640 quantizes to 768 at construction, before `CoverImageClient` sees it. The client does
    // not re-derive or mutate the width.
    let request = try CoverRequest(itemID: "item-42", width: 640)

    let task = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data())
    )
    _ = try await task.value

    let sent = await transport.requests
    #expect(sent[0].url.absoluteString == "https://books.example.test/api/items/item-42/cover?format=webp&width=768")
  }

  @Test("a client composed for JPEG asks for JPEG when fetching by artwork key")
  func jpegClientRequestsJPEGForArtworkKeys() async throws {
    let scope = ArtworkAccountScope("account-hash")
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport, artworkScope: scope, format: .jpeg)
    let key = ArtworkKey(
      accountScope: scope, itemID: "item-42", variant: .libraryThumbnail(pixelWidth: 96),
      revision: .unversioned)

    let task = Task { try await client.fetch(key) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/jpeg"], body: Data([1])))
    _ = try await task.value

    let sent = await transport.requests
    #expect(sent[0].url.absoluteString == "https://books.example.test/api/items/item-42/cover?format=jpeg&width=96")
    #expect(await client.data(for: key) == Data([1]))
  }

  @Test(
    "distinct quantized widths still coalesce independently: same step shares a transport request, different steps don't"
  )
  func distinctQuantizedWidthsStillCoalesceIndependently() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)

    // 600 and 700 are both at or above the high-fidelity floor and both quantize to 768 (256px
    // step) for the same item, so under `CoalescingKey(itemID, width)` both calls coalesce onto
    // one transport request.
    let sameStepA = try CoverRequest(itemID: "item-1", width: 600)
    let sameStepB = try CoverRequest(itemID: "item-1", width: 700)
    #expect(sameStepA.width == sameStepB.width)

    // 900 quantizes to a different step (1024) for the same item, so it must not coalesce with the
    // 768 requests above. It is a distinct cache and coalescing entry.
    let differentStep = try CoverRequest(itemID: "item-1", width: 900)
    #expect(differentStep.width != sameStepA.width)

    let taskA = Task { try await client.fetch(sameStepA) }
    let taskB = Task { try await client.fetch(sameStepB) }
    try await waitUntil { await transport.requests.count == 1 }
    #expect(await transport.requests.count == 1)

    let taskDifferent = Task { try await client.fetch(differentStep) }
    try await waitUntil { await transport.requests.count == 2 }
    #expect(await transport.requests.count == 2)

    let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data("bytes".utf8))
    await transport.releaseAll(with: response)

    _ = try await taskA.value
    _ = try await taskB.value
    _ = try await taskDifferent.value
    // Still exactly two transport requests: the two same-step calls coalesced onto one, the
    // different-step call issued its own.
    #expect(await transport.requests.count == 2)
  }

  @Test("a stored cover serves a repeat hit without touching transport")
  func storedCoverServesRepeatHitWithoutTransport() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let store = makeStore()
    let client = CoverImageClient(server: server, httpClient: transport, store: store)
    let request = try CoverRequest(itemID: "item-1", width: 400)
    seed(store, with: request, server: server, body: Data("already-cached".utf8))

    let result = try await client.fetch(request)

    #expect(result.data == Data("already-cached".utf8))
    #expect(result.contentType == "image/webp")
    #expect(await transport.requests.isEmpty)
  }

  @Test("a 1024px response survives recreation of the store and client")
  func diskCacheSurvivesClientRecreation() async throws {
    let directory = try makeTemporaryDirectory("disk-survival")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let request = try CoverRequest(itemID: "item-1", width: 1024)
    let body = Data(repeating: 0x5A, count: 128 * 1024)

    try await populateDiskCache(
      directory: directory, server: server, request: request, body: body)

    // A store built fresh over the directory, as the next launch builds one: nothing but the file
    // can answer.
    let secondTransport = FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport())
    let secondClient = CoverImageClient(
      server: server, httpClient: secondTransport, store: CoverFileStore(root: directory))
    let result = try await secondClient.fetch(request)

    #expect(result.data == body)
    #expect(secondTransport.requests.isEmpty)
  }

  @Test("a failed fetch does not poison the coalescing map: a later retry issues a fresh request")
  func failureDoesNotPoisonCoalescingMap() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 400)

    let firstTask = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(with: HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    await #expect(throws: APIError.self) {
      try await firstTask.value
    }

    // A fresh call for the identical request issues a brand new transport request rather than
    // reusing whatever the failed attempt left behind.
    let secondTask = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 2 }
    #expect(await transport.requests.count == 2)

    let body = Data("recovered".utf8)
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: body)
    )
    let result = try await secondTask.value
    #expect(result.data == body)
  }

  @Test("cancelling one waiter leaves the other waiters for the same cover served")
  func cancellationOfOneWaiterLeavesOthersServed() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 400)

    let cancelled = Task { try await client.fetch(request) }
    let survivor1 = Task { try await client.fetch(request) }
    let survivor2 = Task { try await client.fetch(request) }

    try await waitUntil { await transport.requests.count == 1 }
    cancelled.cancel()

    let body = Data("cover-bytes".utf8)
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: body)
    )

    let result1 = try await survivor1.value
    let result2 = try await survivor2.value
    #expect(result1.data == body)
    #expect(result2.data == body)
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    // Cancelling one waiter never caused a second transport request for the same cover.
    #expect(await transport.requests.count == 1)
    #expect(await transport.cancellationCount == 0)
  }

  @Test("cancelling every waiter cancels transport and clears the coalescing entry")
  func cancellingEveryWaiterCancelsTransport() async throws {
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 400)
    let first = Task { try await client.fetch(request) }
    let second = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    #expect(await client.inFlightRequestCountForTesting == 1)

    first.cancel()
    second.cancel()

    try await waitUntil { await transport.cancellationCount == 1 }
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(await client.inFlightRequestCountForTesting == 0)
  }

  @Test("a fresh fetch after full cancellation starts a new transport")
  func fetchAfterFullCancellationStartsFreshTransport() async throws {
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport)
    let request = try CoverRequest(itemID: "item-1", width: 400)
    let cancelled = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    cancelled.cancel()
    try await waitUntil { await transport.cancellationCount == 1 }
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    let retry = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 2 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"],
        body: Data("fresh".utf8)))

    #expect(try await retry.value.data == Data("fresh".utf8))
  }

  @Test("cache-only data lookup returns bytes without transport")
  func dataForKeyResolvesFromTheCompressedTierOnly() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let store = makeStore()
    let client = CoverImageClient(server: server, httpClient: transport, store: store)
    let request = try CoverRequest(itemID: "item-1", width: 132)
    seed(store, with: request, server: server)

    let result = await client.data(for: request)

    #expect(result == Data("seeded-cover".utf8))
    #expect(await transport.requests.isEmpty)
  }

  @Test("a cover fetched through one address is served through another address of the account")
  func compressedCoversSurviveAnAddressSwitch() async throws {
    let scope = ArtworkAccountScope("abs:namespace-1#account=1")
    let store = makeStore()
    let request = try CoverRequest(itemID: "item-1", width: 132)
    let body = Data("lan-cover".utf8)
    let transport = BlockingHTTPClient()
    let lan = CoverImageClient(
      server: try makeServer("http://192.168.0.10:13378"), httpClient: transport, store: store,
      artworkScope: scope)
    let fetch = Task { try await lan.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: body))
    #expect(try await fetch.value.data == body)

    let tailnet = CoverImageClient(
      server: try makeServer("http://100.69.69.27:13378"),
      httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      store: store, artworkScope: scope)
    #expect(await tailnet.data(for: request) == body)
    #expect(try await tailnet.fetch(request).data == body)

    let otherAccount = CoverImageClient(
      server: try makeServer("http://100.69.69.27:13378"),
      httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      store: store, artworkScope: ArtworkAccountScope("abs:namespace-2#account=2"))
    #expect(await otherAccount.data(for: request) == nil)
  }

  @Test(
    "a cover cached by an older build is moved into the store on first hit",
    arguments: [LegacyKeyShape.canonical, .fullURL])
  func legacyEntriesMigrateOnFirstHit(_ shape: LegacyKeyShape) async throws {
    let directory = try makeTemporaryDirectory("legacy")
    defer { try? FileManager.default.removeItem(at: directory) }
    let scope = ArtworkAccountScope("abs:namespace-1#account=1")
    let legacy = makeLegacyCache()
    let store = CoverFileStore(root: directory, legacy: legacy)
    let request = try CoverRequest(itemID: "item-1", width: 132)
    let lanServer = try makeServer("http://192.168.0.10:13378")
    let lan = CoverImageClient(
      server: lanServer, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()), store: store,
      artworkScope: scope)
    let key = try await legacyKey(shape, client: lan, request: request, server: lanServer)
    seedLegacy(legacy, key: key, mimeType: "image/webp", body: Data("seeded-cover".utf8))

    #expect(await lan.data(for: request) == Data("seeded-cover".utf8))
    #expect(legacy.cachedResponse(for: key) == nil)

    // Served from the file now, at any address of the account, by a store that has no old cache.
    let tailnet = CoverImageClient(
      server: try makeServer("http://100.69.69.27:13378"),
      httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      store: CoverFileStore(root: directory, legacy: makeLegacyCache()), artworkScope: scope)
    #expect(await tailnet.data(for: request) == Data("seeded-cover".utf8))
  }

  @Test("a presence check counts a cover an older build cached, and moves it")
  func containsMigratesALegacyEntry() async throws {
    let directory = try makeTemporaryDirectory("legacy-contains")
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = makeLegacyCache()
    let store = CoverFileStore(root: directory, legacy: legacy)
    let server = try makeServer()
    let client = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()), store: store)
    let key = ArtworkKey(
      accountScope: client.artworkScope, itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132), revision: .unversioned)
    #expect(await client.contains(key) == false)
    let request = try key.coverRequest()
    seedLegacy(
      legacy, key: try await legacyKey(.canonical, client: client, request: request, server: server),
      mimeType: "image/webp", body: Data("old".utf8))

    #expect(await client.contains(key))
    #expect(store.contains(storeKey(request, server: server)))
  }

  @Test("after a clear, a cover an older build cached is not served")
  func clearDisablesTheLegacyFallthrough() async throws {
    let directory = try makeTemporaryDirectory("legacy-clear")
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = makeLegacyCache()
    let store = CoverFileStore(root: directory, legacy: legacy)
    let server = try makeServer()
    let client = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()), store: store)
    let request = try CoverRequest(itemID: "item-1", width: 132)
    let key = try await legacyKey(.canonical, client: client, request: request, server: server)
    seedLegacy(legacy, key: key, mimeType: "image/webp", body: Data("old".utf8))

    await client.clearCachedArtwork()

    #expect(await client.data(for: request) == nil)
    #expect(store.hasLegacyCacheForTesting == false)
  }

  @Test("compressed cache entries are exact per pixel width")
  func compressedCacheEntriesAreExactPerPixelWidth() async throws {
    let server = try makeServer()
    let transport = FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport())
    let store = makeStore()
    let client = CoverImageClient(server: server, httpClient: transport, store: store)
    let thumbnail = try CoverRequest(itemID: "item-1", width: 132)
    let highFidelity = try CoverRequest(itemID: "item-1", width: 1024)

    seed(store, with: highFidelity, server: server)
    #expect(await client.data(for: thumbnail) == nil)

    seed(store, with: thumbnail, server: server)
    #expect(await client.data(for: thumbnail) != nil)
    _ = try await client.fetch(thumbnail)
    #expect(transport.requests.isEmpty)
  }

  @Test("a cached cover is a miss once the item's revision moves")
  func compressedCacheEntriesAreExactPerRevision() async throws {
    let server = try makeServer()
    let transport = FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport())
    let store = makeStore()
    let client = CoverImageClient(server: server, httpClient: transport, store: store)
    let old = try CoverRequest(itemID: "item-1", width: 768, revision: ArtworkRevision("1"))
    let replaced = try CoverRequest(itemID: "item-1", width: 768, revision: ArtworkRevision("2"))

    seed(store, with: old, server: server)

    #expect(await client.data(for: old) != nil)
    #expect(await client.data(for: replaced) == nil)
  }

  @Test("requests for different revisions of one cover do not coalesce")
  func distinctRevisionsDoNotCoalesce() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)
    let old = try CoverRequest(itemID: "item-1", width: 768, revision: ArtworkRevision("1"))
    let replaced = try CoverRequest(itemID: "item-1", width: 768, revision: ArtworkRevision("2"))

    let first = Task { try await client.fetch(old) }
    try await waitUntil { await transport.requests.count == 1 }
    let second = Task { try await client.fetch(replaced) }
    try await waitUntil { await transport.requests.count == 2 }

    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data("cover".utf8)))
    _ = try await first.value
    _ = try await second.value
    #expect(await transport.requests.count == 2)
  }

  @Test("clearing cached artwork empties the in-memory cover tier")
  func clearCachedArtworkEmptiesTheMemoryTier() async throws {
    let server = try makeServer()
    let store = makeStore()
    let client = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()), store: store)
    let request = try CoverRequest(itemID: "item-1", width: 132)
    seed(store, with: request, server: server)
    #expect(await client.data(for: request) == Data("seeded-cover".utf8))

    await client.clearCachedArtwork()

    #expect(await client.data(for: request) == nil)
  }

  @Test("legacy cached responses are admitted by the same MIME policy as transport")
  func invalidLegacyCacheEntriesAreEvictedAndRefetched() async throws {
    let directory = try makeTemporaryDirectory("legacy-mime")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let request = try CoverRequest(itemID: "legacy", width: 132)
    let legacy = makeLegacyCache()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: server, httpClient: transport, store: CoverFileStore(root: directory, legacy: legacy))
    let key = try await legacyKey(.fullURL, client: client, request: request, server: server)
    seedLegacy(legacy, key: key, mimeType: "text/html", body: Data("oops".utf8))

    let fetch = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"],
        body: Data("fresh".utf8)))

    #expect(try await fetch.value.data == Data("fresh".utf8))
    #expect(legacy.cachedResponse(for: key) == nil)
  }

  @Test("an oversized legacy cache entry is evicted before it can be returned")
  func oversizedLegacyCacheEntryIsEvicted() async throws {
    let directory = try makeTemporaryDirectory("legacy-oversize")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let request = try CoverRequest(itemID: "oversized-legacy", width: 132)
    let legacy = URLCache(memoryCapacity: 512 * 1024 * 1024, diskCapacity: 0, directory: nil)
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: server, httpClient: transport, store: CoverFileStore(root: directory, legacy: legacy))
    let key = try await legacyKey(.fullURL, client: client, request: request, server: server)
    seedLegacy(
      legacy, key: key, mimeType: "image/webp",
      body: Data(repeating: 0x5A, count: CoverImageLimits.maximumResponseBytes + 1))

    let fetch = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }
    await transport.releaseAll(
      with: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "image/webp"], body: Data()))

    #expect(try await fetch.value.data.isEmpty)
  }

  @Test("an oversized file in the store is rejected and removed on read")
  func oversizedStoredFileIsRejectedOnRead() async throws {
    let directory = try makeTemporaryDirectory("oversize-file")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let store = CoverFileStore(root: directory)
    let request = try CoverRequest(itemID: "item-1", width: 132)
    seed(
      store, with: request, server: server,
      body: Data(repeating: 0x5A, count: CoverImageLimits.maximumResponseBytes + 1))
    let client = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()), store: store)

    #expect(await client.data(for: request) == nil)
    #expect(store.contains(storeKey(request, server: server)) == false)
  }

  @Test("clearing cached artwork empties a directory-backed cover cache")
  func clearCachedArtworkEmptiesTheDiskBackedCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoverImageClientTests-clear-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try makeServer()
    let request = try CoverRequest(itemID: "item-1", width: 1024)
    let body = Data(repeating: 0x5A, count: 64 * 1024)
    // Populated through a real fetch on a separate client, then read back by a second instance:
    // the entry then lives on disk rather than in this client's memory tier, which is the case
    // `URLCache.removeAllCachedResponses()` alone does not empty.
    try await populateDiskCache(directory: directory, server: server, request: request, body: body)
    let client = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      cacheDirectory: directory)
    #expect(await client.data(for: request) == body)

    await client.clearCachedArtwork()

    #expect(await client.data(for: request) == nil)
    let rebuilt = CoverImageClient(
      server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
      cacheDirectory: directory)
    #expect(await rebuilt.data(for: request) == nil)
  }

  @Test("clearing cancels and drains an active cover fetch before purging")
  func clearCachedArtworkDrainsAnActiveFetch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoverImageClientTests-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(
      server: try makeServer(), httpClient: transport, cacheDirectory: directory)
    let request = try CoverRequest(itemID: "in-flight-at-removal", width: 1024)
    let fetch = Task { try await client.fetch(request) }
    try await waitUntil { await transport.requests.count == 1 }

    await client.clearCachedArtwork()

    await #expect(throws: CancellationError.self) {
      _ = try await fetch.value
    }
    #expect(await transport.cancellationCount == 1)
    #expect(await client.inFlightRequestCountForTesting == 0)
    // The purged directory is reopened for continued use: a fetch admitted a moment before the
    // clear can no longer land in it, which is what the drain above establishes.
    #expect(await client.data(for: request) == nil)
  }

  /// Repeated because the failure it guards against was intermittent: purging a live store and
  /// storing into it straight afterwards lost the new cover in roughly one run in six.
  @Test("a cover fetched after a clear is kept on disk", arguments: 0..<8)
  func coverFetchedAfterClearIsKeptOnDisk(_ attempt: Int) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoverImageClientTests-refill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await expectClearThenRefillPersists(directory: directory)
  }

  @Test("cache-only data lookup misses without starting a transfer")
  func dataForKeyNeverStartsATransferOnAMiss() async throws {
    let server = try makeServer()
    let transport = BlockingHTTPClient()
    let client = CoverImageClient(server: server, httpClient: transport)

    let result = await client.data(for: try CoverRequest(itemID: "cold", width: 132))

    #expect(result == nil)
    #expect(await transport.requests.isEmpty)
  }
}

private func makeServer(_ url: String = "https://books.example.test") throws -> ABSServerConfig {
  try ABSServerConfig(url: #require(URL(string: url)))
}

/// Memory-only per test: no disk I/O and no cross-test contamination.
private func makeStore() -> CoverFileStore {
  CoverFileStore(memoryCapacity: 64 * 1024 * 1024)
}

/// Stands in for the `URLCache` an older build left behind.
private func makeLegacyCache() -> URLCache {
  URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 0, directory: nil)
}

private func makeTemporaryDirectory(_ label: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CoverImageClientTests-\(label)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

enum LegacyKeyShape: Sendable {
  /// The address-independent key the last `URLCache` builds stored under.
  case canonical
  /// The full request URL, from builds before that.
  case fullURL
}

private func legacyKey(
  _ shape: LegacyKeyShape, client: CoverImageClient, request: CoverRequest, server: ABSServerConfig
) async throws -> URLRequest {
  let httpRequest = try request.makeRequest(using: RequestBuilder(server: server))
  switch shape {
  case .canonical: return await client.legacyCanonicalKey(for: request, httpRequest: httpRequest)
  case .fullURL: return URLRequest(url: httpRequest.url)
  }
}

private func seedLegacy(_ cache: URLCache, key: URLRequest, mimeType: String, body: Data) {
  guard let url = key.url else { return }
  let response = URLResponse(
    url: url, mimeType: mimeType, expectedContentLength: body.count, textEncodingName: nil)
  cache.storeCachedResponse(CachedURLResponse(response: response, data: body), for: key)
}

private func storeKey(
  _ request: CoverRequest, server: ABSServerConfig, scope: ArtworkAccountScope? = nil
) -> CoverStoreKey {
  CoverStoreKey(
    scope: scope ?? ArtworkAccountScope(server.baseURL.absoluteString), itemID: request.itemID,
    width: request.width, revision: request.revision, format: request.format)
}

private func populateDiskCache(
  directory: URL,
  server: ABSServerConfig,
  request: CoverRequest,
  body: Data
) async throws {
  let transport = BlockingHTTPClient()
  let client = CoverImageClient(server: server, httpClient: transport, cacheDirectory: directory)
  let fetch = Task { try await client.fetch(request) }
  try await waitUntil { await transport.requests.count == 1 }
  await transport.releaseAll(
    with: HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "image/webp"], body: body))
  #expect(try await fetch.value.data == body)
}

/// Clears a warm directory-backed client, fetches a new cover through it, and checks that a client
/// rebuilt over the same root (the next launch) serves that cover without transport. The Library
/// Cache census depends on this once a pass outgrows the 20 MB memory tier.
private func expectClearThenRefillPersists(
  directory: URL, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let server = try makeServer()
  let stale = try CoverRequest(itemID: "before-clear", width: 1024)
  try await populateDiskCache(
    directory: directory, server: server, request: stale, body: Data(repeating: 0x11, count: 4096))
  let transport = BlockingHTTPClient()
  let client = CoverImageClient(server: server, httpClient: transport, cacheDirectory: directory)
  #expect(await client.data(for: stale) != nil, sourceLocation: sourceLocation)

  await client.clearCachedArtwork()
  #expect(await client.data(for: stale) == nil, sourceLocation: sourceLocation)

  let fresh = try CoverRequest(itemID: "after-clear", width: 1024)
  let body = Data(repeating: 0x22, count: 64 * 1024)
  let fetch = Task { try await client.fetch(fresh) }
  try await waitUntil { await transport.requests.count == 1 }
  await transport.releaseAll(
    with: HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: body))
  #expect(try await fetch.value.data == body, sourceLocation: sourceLocation)

  let rebuilt = CoverImageClient(
    server: server, httpClient: FakeHTTPClient(transportFailure: UnexpectedDiskCacheTransport()),
    store: CoverFileStore(root: directory))
  #expect(await rebuilt.data(for: fresh) == body, sourceLocation: sourceLocation)
  #expect(await rebuilt.data(for: stale) == nil, sourceLocation: sourceLocation)
}

/// Puts a cover for `request` into `store` without going near the transport, so a test can set up
/// a warm entry without racing a blocked fetch. Mirrors the write the client itself performs.
private func seed(
  _ store: CoverFileStore, with request: CoverRequest, server: ABSServerConfig,
  body: Data = Data("seeded-cover".utf8)
) {
  store.write(body, for: storeKey(request, server: server))
}

/// Thrown when `waitUntil` gives up, so the caller stops rather than continuing into code that
/// assumed the condition held.
private struct ConditionNeverBecameTrue: Error {}

/// Callers wait for N requests to reach the transport, then release them and await the fetch task.
/// If the wait gives up, the release resolves nothing and the following `await task.value` waits
/// on a continuation that is never resumed, so the test process hangs instead of failing. This
/// throws on top of the shared waiter's recorded issue so a lost race fails fast.
private func waitUntil(
  _ condition: @escaping @Sendable () async -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  guard await TestSupport.waitUntil(sourceLocation: sourceLocation, condition) else {
    throw ConditionNeverBecameTrue()
  }
}

private struct UnexpectedDiskCacheTransport: Error {}

// Kept: tests read its peak in-flight count, cancellation count and FIFO release, and FakeHTTPClient
// has no such seam; reproducing it over a handler would be a wrapper double with 35 call sites.
/// Fake raw transport that never resolves a request until the test releases it, so completion
/// order and in-flight counts are fully test-controlled (no sleeps). Mirrors the pattern already
/// established by `CompositionTransport` in `ABSClientCompositionTests.swift`.
private actor BlockingHTTPClient: HTTPClienting {
  private(set) var requests: [HTTPRequest] = []
  private(set) var maxInFlight = 0
  private(set) var cancellationCount = 0
  private var currentInFlight = 0
  private var pendingIDs: [UUID] = []
  private var waiters: [UUID: CheckedContinuation<HTTPResponse, Error>] = [:]

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    currentInFlight += 1
    maxInFlight = max(maxInFlight, currentInFlight)
    defer { currentInFlight -= 1 }

    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard Task.isCancelled == false else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters[id] = continuation
        pendingIDs.append(id)
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  /// Resolves the longest-waiting still-pending request (FIFO), if any.
  func releaseOldest(with response: HTTPResponse) {
    guard pendingIDs.isEmpty == false else { return }
    let id = pendingIDs.removeFirst()
    waiters.removeValue(forKey: id)?.resume(returning: response)
  }

  func releaseAll(with response: HTTPResponse) {
    let ids = pendingIDs
    pendingIDs.removeAll()
    for id in ids {
      waiters.removeValue(forKey: id)?.resume(returning: response)
    }
  }

  private func cancel(id: UUID) {
    guard let continuation = waiters.removeValue(forKey: id) else { return }
    pendingIDs.removeAll { $0 == id }
    cancellationCount += 1
    continuation.resume(throwing: CancellationError())
  }
}
