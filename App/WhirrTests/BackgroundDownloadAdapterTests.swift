import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// `BackgroundDownloadSessionAdapter`: the App's `BackgroundTransferring` conformance over a
/// background-configured `URLSession`. Tests drive the adapter through injected session, task and
/// mover shims (in `Fakes/`). None creates a real background session.
@Suite("BackgroundDownloadSessionAdapter")
struct BackgroundDownloadAdapterTests {

  // MARK: - session configuration

  @Test("background download configuration disables cookies, credentials, and cache reuse")
  func backgroundDownloadConfigurationIsIsolated() async throws {
    let configuration = RealBackgroundDownloadSessionFactory.makeConfiguration(
      identifier: "test.background.session")

    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpMaximumConnectionsPerHost == 2)
    #expect(configuration.timeoutIntervalForRequest == 300)
    #expect(configuration.timeoutIntervalForResource == 86_400)
  }

  // MARK: - enqueue

  @Test("enqueue converts AuthorizedDownloadRequest into a URLRequest preserving headers exactly, adding nothing")
  func enqueueConvertsRequestPreservingHeadersExactly() async throws {
    let request = try await makeAuthorizedDownloadRequest(accessToken: "access-token-1")
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)

    await adapter.enqueue(request, destination: makeDestination(identity: .abs(rowID: 1)))

    let expected = request.makeURLRequest()
    let sent = try #require(fakeSession.madeRequests.first)
    #expect(sent.url == expected.url)
    #expect(sent.httpMethod == expected.httpMethod)
    #expect(sent.timeoutInterval == expected.timeoutInterval)
    #expect(sent.allHTTPHeaderFields == expected.allHTTPHeaderFields)
  }

  @Test("enqueue resumes the newly created task")
  func enqueueResumesTask() async throws {
    let request = try await makeAuthorizedDownloadRequest(accessToken: "access-token-1")
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)

    await adapter.enqueue(request, destination: makeDestination(identity: .abs(rowID: 1)))

    #expect(fakeSession.madeTasks.first?.resumeCallCount == 1)
  }

  @Test("enqueue gives the background scheduler the expected receive size")
  func enqueueSetsExpectedReceiveSize() async throws {
    let request = try await makeAuthorizedDownloadRequest(accessToken: "access-token-1")
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)

    await adapter.enqueue(request, destination: makeDestination(identity: .abs(rowID: 1)))

    #expect(fakeSession.madeTasks.first?.countOfBytesClientExpectsToReceive == 123_456)
  }

  // MARK: - progress

  @Test("progress tolerates an unknown expected length")
  func progressTolerantOfUnknownExpectedLength() async throws {
    let adapter = makeAdapter()
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleProgress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: -1)

    let event = await iterator.next()
    #expect(event == .progress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: nil))
  }

  @Test("progress carries a known expected length through unchanged")
  func progressCarriesKnownExpectedLength() async throws {
    let adapter = makeAdapter()
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleProgress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: 500)

    let event = await iterator.next()
    #expect(event == .progress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: 500))
  }

  @Test("progress callbacks are coalesced to four database-facing updates per second")
  func progressCallbacksAreCoalesced() async throws {
    let clock = FakeProgressClock()
    let adapter = makeAdapter(progressNow: { clock.now })
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleProgress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: 1_000)
    clock.now = 0.1
    adapter.handleProgress(identity: .abs(rowID: 7), receivedBytes: 200, expectedBytes: 1_000)
    clock.now = 0.25
    adapter.handleProgress(identity: .abs(rowID: 7), receivedBytes: 300, expectedBytes: 1_000)

    let first = await iterator.next()
    let second = await iterator.next()
    #expect(first == .progress(identity: .abs(rowID: 7), receivedBytes: 100, expectedBytes: 1_000))
    #expect(second == .progress(identity: .abs(rowID: 7), receivedBytes: 300, expectedBytes: 1_000))
  }

  @Test("progress over the defensive byte limit cancels and reports a dedicated failure")
  func progressOverrunCancelsAndReportsDedicatedFailure() async throws {
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)
    await enqueueFixture(adapter, destination: makeDestination(identity: .abs(rowID: 8)))
    let task = try #require(fakeSession.madeTasks.first)
    var iterator = adapter.events.makeAsyncIterator()

    let expectedSize: Int64 = 123_456
    let byteLimit = expectedSize + max(expectedSize / 10, 1_048_576)
    adapter.handleProgress(identity: .abs(rowID: 8), receivedBytes: 100, expectedBytes: expectedSize)
    #expect(
      await iterator.next() == .progress(identity: .abs(rowID: 8), receivedBytes: 100, expectedBytes: expectedSize))

    adapter.handleProgress(identity: .abs(rowID: 8), receivedBytes: byteLimit + 1, expectedBytes: expectedSize)

    #expect(task.cancelCallCount == 1)
    let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    adapter.handleTaskCompletion(identity: .abs(rowID: 8), error: cancellation)
    #expect(
      await iterator.next()
        == .failed(identity: .abs(rowID: 8), errorDomain: "whirr.adapter.overrun", errorCode: NSURLErrorCancelled))
  }

  @Test("an ordinary user cancellation keeps the system cancellation domain")
  func ordinaryCancellationKeepsSystemErrorDomain() async throws {
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)
    await enqueueFixture(adapter, destination: makeDestination(identity: .abs(rowID: 9)))

    await adapter.cancel(identity: .abs(rowID: 9))
    #expect(fakeSession.madeTasks.first?.cancelCallCount == 1)

    var iterator = adapter.events.makeAsyncIterator()
    let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    adapter.handleTaskCompletion(identity: .abs(rowID: 9), error: cancellation)
    #expect(
      await iterator.next()
        == .failed(identity: .abs(rowID: 9), errorDomain: NSURLErrorDomain, errorCode: NSURLErrorCancelled))
  }

  @Test("zero-size and reattached downloads have no defensive byte limit")
  func zeroSizeAndReattachedDownloadsAreNotCapped() async throws {
    let zeroSizeSession = FakeBackgroundDownloadSessionProviding()
    let zeroSizeAdapter = makeAdapter(session: zeroSizeSession)
    let zeroSizeRequest = try await makeAuthorizedDownloadRequest(
      accessToken: "zero-size-access", expectedSize: 0)
    await zeroSizeAdapter.enqueue(zeroSizeRequest, destination: makeDestination(identity: .abs(rowID: 11)))
    let zeroSizeTask = try #require(zeroSizeSession.madeTasks.first)
    var zeroSizeIterator = zeroSizeAdapter.events.makeAsyncIterator()

    zeroSizeAdapter.handleProgress(identity: .abs(rowID: 11), receivedBytes: 10_000_000, expectedBytes: -1)

    #expect(zeroSizeTask.cancelCallCount == 0)
    #expect(
      await zeroSizeIterator.next()
        == .progress(identity: .abs(rowID: 11), receivedBytes: 10_000_000, expectedBytes: nil))

    let sharedSession = FakeBackgroundDownloadSessionProviding()
    let firstAdapter = makeAdapter(session: sharedSession)
    await enqueueFixture(firstAdapter, destination: makeDestination(identity: .abs(rowID: 12)))
    sharedSession.pendingTasksToReturn = sharedSession.madeTasks
    let reattachedAdapter = makeAdapter(session: sharedSession)
    let reattachedTask = try #require(sharedSession.madeTasks.first)
    var reattachedIterator = reattachedAdapter.events.makeAsyncIterator()

    reattachedAdapter.handleProgress(identity: .abs(rowID: 12), receivedBytes: 10_000_000, expectedBytes: -1)

    #expect(reattachedTask.cancelCallCount == 0)
    #expect(
      await reattachedIterator.next()
        == .progress(identity: .abs(rowID: 12), receivedBytes: 10_000_000, expectedBytes: nil))
  }

  // MARK: - redirects

  @Test("same-origin redirect is passed through unchanged")
  func sameOriginRedirectIsAllowed() async throws {
    let adapter = makeAdapter()
    let task = FakeBackgroundDownloadTaskHandle()
    let requestURL = URL(string: "https://books.example.test/api/items/item-1/file/42/download")!
    var completionValue: URLRequest?
    var request = URLRequest(url: requestURL)
    request.setValue("audio/mp4", forHTTPHeaderField: "Accept")

    adapter.handleRedirect(
      identity: .abs(rowID: 20),
      task: task,
      originalURL: URL(string: "https://books.example.test/api/items/item-1/file/42")!,
      request: request,
      completionHandler: { completionValue = $0 })

    #expect(completionValue?.url == request.url)
    #expect(completionValue?.allHTTPHeaderFields == request.allHTTPHeaderFields)
    #expect(task.cancelCallCount == 0)
  }

  @Test("cross-host and HTTPS-to-HTTP redirects are denied")
  func unsafeRedirectsAreDenied() async throws {
    let adapter = makeAdapter()
    let originalURL = URL(string: "https://books.example.test/api/download")!
    let targets = [
      URL(string: "https://other.example.test/api/download")!,
      URL(string: "http://books.example.test/api/download")!,
    ]

    for (index, target) in targets.enumerated() {
      let task = FakeBackgroundDownloadTaskHandle()
      var completionValue: URLRequest? = URLRequest(url: originalURL)
      adapter.handleRedirect(
        identity: .abs(rowID: Int64(21 + index)),
        task: task,
        originalURL: originalURL,
        request: URLRequest(url: target),
        completionHandler: { completionValue = $0 })

      #expect(completionValue == nil)
      #expect(task.cancelCallCount == 1)
    }
  }

  @Test("denied redirect cancellation reports the redirect-denied domain")
  func deniedRedirectCancellationReportsDedicatedFailure() async throws {
    let adapter = makeAdapter()
    let task = FakeBackgroundDownloadTaskHandle()
    var completionValue: URLRequest? = URLRequest(
      url: URL(string: "https://books.example.test/api/download")!)
    adapter.handleRedirect(
      identity: .abs(rowID: 23),
      task: task,
      originalURL: URL(string: "https://books.example.test/api/download")!,
      request: URLRequest(url: URL(string: "https://other.example.test/api/download")!),
      completionHandler: { completionValue = $0 })

    #expect(completionValue == nil)
    #expect(task.cancelCallCount == 1)

    var iterator = adapter.events.makeAsyncIterator()
    let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    adapter.handleTaskCompletion(identity: .abs(rowID: 23), error: cancellation)
    #expect(
      await iterator.next()
        == .failed(
          identity: .abs(rowID: 23), errorDomain: "whirr.adapter.redirectDenied",
          errorCode: NSURLErrorCancelled))
  }

  @Test("RSS cross-origin redirect is allowed with Authorization stripped")
  func feedCrossOriginRedirectStripsAuthorization() async throws {
    let session = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: session)
    let identity = TransferIdentity.rss(rowID: 30)
    await adapter.enqueue(
      makeFeedTransferRequest(),
      destination: makeDestination(identity: identity))
    let task = try #require(session.madeTasks.first)
    let originalURL = URL(string: "https://feed.example.test/episode.mp3")!
    var request = URLRequest(url: URL(string: "https://cdn.example.test/episode.mp3")!)
    request.setValue("Bearer feed-secret", forHTTPHeaderField: "Authorization")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    var completionValue: URLRequest?

    adapter.handleRedirect(
      identity: identity, task: task, originalURL: originalURL, request: request,
      completionHandler: { completionValue = $0 })

    #expect(task.cancelCallCount == 0)
    #expect(completionValue?.url == request.url)
    #expect(completionValue?.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(completionValue?.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
  }

  @Test("RSS same-origin redirect retains Authorization")
  func feedSameOriginRedirectRetainsAuthorization() async throws {
    let session = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: session)
    let identity = TransferIdentity.rss(rowID: 31)
    await adapter.enqueue(
      makeFeedTransferRequest(),
      destination: makeDestination(identity: identity))
    let task = try #require(session.madeTasks.first)
    let originalURL = URL(string: "https://feed.example.test/episode.mp3")!
    var request = URLRequest(url: URL(string: "https://feed.example.test/episode-v2.mp3")!)
    request.setValue("Bearer feed-secret", forHTTPHeaderField: "Authorization")
    var completionValue: URLRequest?

    adapter.handleRedirect(
      identity: identity, task: task, originalURL: originalURL, request: request,
      completionHandler: { completionValue = $0 })

    #expect(task.cancelCallCount == 0)
    #expect(completionValue?.value(forHTTPHeaderField: "Authorization") == "Bearer feed-secret")
  }

  @Test("RSS redirect rejects HTTPS downgrade and the sixth hop")
  func feedRedirectRejectsDowngradeAndSixthHop() async throws {
    let session = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: session)
    let downgradeIdentity = TransferIdentity.rss(rowID: 32)
    await adapter.enqueue(
      makeFeedTransferRequest(),
      destination: makeDestination(identity: downgradeIdentity))
    let downgradeTask = try #require(session.madeTasks.first)
    var downgradeCompletion: URLRequest? = URLRequest(url: URL(string: "https://feed.example.test")!)
    adapter.handleRedirect(
      identity: downgradeIdentity, task: downgradeTask,
      originalURL: URL(string: "https://feed.example.test/episode.mp3")!,
      request: URLRequest(url: URL(string: "http://cdn.example.test/episode.mp3")!),
      completionHandler: { downgradeCompletion = $0 })
    #expect(downgradeCompletion == nil)
    #expect(downgradeTask.cancelCallCount == 1)

    let hopIdentity = TransferIdentity.rss(rowID: 33)
    await adapter.enqueue(
      makeFeedTransferRequest(),
      destination: makeDestination(identity: hopIdentity))
    let hopTask = try #require(session.madeTasks.last)
    let originalURL = URL(string: "https://feed.example.test/episode.mp3")!
    for hop in 1...FeedRedirectPolicy.maximumHops {
      var completion: URLRequest?
      adapter.handleRedirect(
        identity: hopIdentity, task: hopTask, originalURL: originalURL,
        request: URLRequest(url: URL(string: "https://cdn.example.test/hop-\(hop).mp3")!),
        completionHandler: { completion = $0 })
      #expect(completion != nil)
    }
    var sixthCompletion: URLRequest? = URLRequest(url: originalURL)
    adapter.handleRedirect(
      identity: hopIdentity, task: hopTask, originalURL: originalURL,
      request: URLRequest(url: URL(string: "https://cdn.example.test/hop-6.mp3")!),
      completionHandler: { sixthCompletion = $0 })
    #expect(sixthCompletion == nil)
    #expect(hopTask.cancelCallCount == 1)
  }

  @Test("RSS redirect hop and task metadata survive reattachment")
  func feedRedirectMetadataSurvivesReattachment() async throws {
    let sharedSession = FakeBackgroundDownloadSessionProviding()
    let factory: BackgroundDownloadSessionFactory = { _, _, _ in sharedSession }
    let identity = TransferIdentity.rss(rowID: 34)
    let first = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session", fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory)
    let destination = makeDestination(identity: identity)
    await first.enqueue(makeFeedTransferRequest(), destination: destination)
    let task = try #require(sharedSession.madeTasks.first)
    let originalURL = URL(string: "https://feed.example.test/episode.mp3")!
    for hop in 1...2 {
      var completion: URLRequest?
      first.handleRedirect(
        identity: identity, task: task, originalURL: originalURL,
        request: URLRequest(url: URL(string: "https://cdn.example.test/hop-\(hop).mp3")!),
        completionHandler: { completion = $0 })
      #expect(completion != nil)
    }
    sharedSession.pendingTasksToReturn = [task]
    let second = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session", fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory)
    var request = URLRequest(url: URL(string: "https://cdn.example.test/hop-3.mp3")!)
    request.setValue("Bearer feed-secret", forHTTPHeaderField: "Authorization")
    var completionValue: URLRequest?
    second.handleRedirect(
      identity: identity, task: task, originalURL: originalURL, request: request,
      completionHandler: { completionValue = $0 })

    #expect(task.cancelCallCount == 0)
    #expect(completionValue?.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(task.taskDescription?.contains("rss:34") == true)
    #expect(task.taskDescription?.contains("\"hopCount\":3") == true)
  }

  /// The inverse of the "In Our Time" case: the feed declares less than the CDN serves. The
  /// declared length is advisory, so it must not become the in-flight bound. Only the absolute cap
  /// is, and it still cancels an oversized transfer.
  @Test("a feed transfer is bounded by the absolute cap, never by its declared length")
  func feedDeclaredLengthNeverBoundsTheTransferButTheCapStillDoes() async throws {
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)
    let identity = TransferIdentity.rss(rowID: 36)
    let declared: Int64 = 20_000_000
    await adapter.enqueue(
      makeFeedTransferRequest(expectedBytes: declared), destination: makeDestination(identity: identity))
    let task = try #require(fakeSession.madeTasks.first)
    var iterator = adapter.events.makeAsyncIterator()

    let wellPastDeclaredTolerance = declared * 2
    adapter.handleProgress(identity: identity, receivedBytes: wellPastDeclaredTolerance, expectedBytes: declared)
    #expect(
      await iterator.next()
        == .progress(identity: identity, receivedBytes: wellPastDeclaredTolerance, expectedBytes: declared))
    #expect(task.cancelCallCount == 0)

    adapter.handleProgress(
      identity: identity, receivedBytes: BackgroundDownloadSessionAdapter.feedSizeCapBytes + 1,
      expectedBytes: declared)
    #expect(task.cancelCallCount == 1)
    adapter.handleTaskCompletion(
      identity: identity, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
    #expect(
      await iterator.next()
        == .failed(identity: identity, errorDomain: "whirr.adapter.overrun", errorCode: NSURLErrorCancelled))
  }

  /// The ABS bound is untouched: the server describes the same local file it serves.
  @Test("the ABS byte limit is still the declared size plus its margin")
  func absByteLimitIsUnchanged() {
    let smallWithMinimumMargin: Int64 = 123_456 + 1_048_576
    let largeWithTenPercent: Int64 = 110_000_000
    #expect(
      BackgroundDownloadSessionAdapter.effectiveByteLimit(expectedBytes: 123_456, policy: .abs)
        == smallWithMinimumMargin)
    #expect(
      BackgroundDownloadSessionAdapter.effectiveByteLimit(expectedBytes: 100_000_000, policy: .abs)
        == largeWithTenPercent)
    #expect(BackgroundDownloadSessionAdapter.effectiveByteLimit(expectedBytes: 0, policy: .abs) == nil)
    #expect(
      BackgroundDownloadSessionAdapter.effectiveByteLimit(expectedBytes: 40_864_000, policy: .feed)
        == BackgroundDownloadSessionAdapter.feedSizeCapBytes)
    #expect(
      BackgroundDownloadSessionAdapter.effectiveByteLimit(expectedBytes: nil, policy: .feed)
        == BackgroundDownloadSessionAdapter.feedSizeCapBytes)
    #expect(BackgroundDownloadSessionAdapter.feedSizeCapBytes == RSSFileStore.sizeCapBytes)
  }

  @Test("unknown-size RSS progress stays indeterminate and its cap survives reattachment")
  func unknownFeedSizeCapSurvivesReattachment() async throws {
    let sharedSession = FakeBackgroundDownloadSessionProviding()
    let factory: BackgroundDownloadSessionFactory = { _, _, _ in sharedSession }
    let identity = TransferIdentity.rss(rowID: 35)
    let first = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session", fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory)
    await first.enqueue(makeFeedTransferRequest(), destination: makeDestination(identity: identity))
    let task = try #require(sharedSession.madeTasks.first)
    sharedSession.pendingTasksToReturn = [task]

    let second = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session", fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory)
    var iterator = second.events.makeAsyncIterator()
    let cap: Int64 = 1_073_741_824

    second.handleProgress(identity: identity, receivedBytes: cap, expectedBytes: -1)
    #expect(
      await iterator.next()
        == .progress(identity: identity, receivedBytes: cap, expectedBytes: nil))
    #expect(task.cancelCallCount == 0)

    second.handleProgress(identity: identity, receivedBytes: cap + 1, expectedBytes: -1)
    #expect(task.cancelCallCount == 1)
    second.handleTaskCompletion(
      identity: identity,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
    #expect(
      await iterator.next()
        == .failed(
          identity: identity, errorDomain: "whirr.adapter.overrun",
          errorCode: NSURLErrorCancelled))
  }

  // MARK: - finish

  @Test("finish carries exact HTTP status, response MIME, and response length")
  func finishCarriesExactResponseMetadata() async throws {
    let mover = FakeBackgroundDownloadFileMoving()
    let adapter = makeAdapter(fileMover: mover)
    let destination = makeDestination(identity: .abs(rowID: 3))
    await enqueueFixture(adapter, destination: destination)
    var iterator = adapter.events.makeAsyncIterator()
    let temporaryFileURL = URL(fileURLWithPath: "/tmp/incoming-3")

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 3),
      temporaryFileURL: temporaryFileURL,
      httpResponse: makeHTTPResponse(
        statusCode: 206, mimeType: "audio/mp4", contentLength: 900,
        contentRange: "bytes 100-999/123456")
    )

    let event = await iterator.next()
    #expect(
      event
        == .finished(
          identity: .abs(rowID: 3),
          temporaryFileURL: destination.destinationURL,
          response: BackgroundTransferResponse(
            httpStatusCode: 206, mimeType: "audio/mp4", contentLength: 900,
            contentRange: "bytes 100-999/123456")
        ))
    #expect(mover.moveCalls.count == 1)
    #expect(mover.moveCalls.first?.from == temporaryFileURL)
    #expect(mover.moveCalls.first?.to == destination.destinationURL)
  }

  @Test("the file-mover runs synchronously inside the finish callback")
  func moverRunsSynchronouslyInsideFinishCallback() async throws {
    let mover = FakeBackgroundDownloadFileMoving()
    let adapter = makeAdapter(fileMover: mover)
    let destination = makeDestination(identity: .abs(rowID: 4))
    await enqueueFixture(adapter, destination: destination)

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 4),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-4"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10)
    )

    // No `await` needed: the synchronous mover call has already run when this assertion runs.
    #expect(mover.moveCalls.count == 1)
  }

  @Test("a mover failure reports failure, never a finish event")
  func moverFailureReportsFailureNeverFinish() async throws {
    let mover = FakeBackgroundDownloadFileMoving()
    mover.errorToThrow = FakeMoveError(message: "disk full")
    let adapter = makeAdapter(fileMover: mover)
    let destination = makeDestination(identity: .abs(rowID: 5))
    await enqueueFixture(adapter, destination: destination)
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 5),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-5"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10)
    )

    let event = await iterator.next()
    #expect(
      event
        == .failed(
          identity: .abs(rowID: 5), errorDomain: "whirr.adapter.moveFailed", errorCode: nil))
  }

  @Test("a terminal finish removes the task from the adapter's live snapshot")
  func terminalFinishRemovesTaskFromSnapshot() async throws {
    let adapter = makeAdapter()
    await enqueueFixture(adapter, destination: makeDestination(identity: .abs(rowID: 5)))
    #expect(await adapter.currentTasks() == [BackgroundTransferSnapshot(identity: .abs(rowID: 5))])

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 5),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-5"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10)
    )

    #expect(await adapter.currentTasks().isEmpty)
  }

  @Test("a 401 finish response maps to an auth challenge, never a finish event")
  func unauthorizedFinishMapsToAuthChallenge() async throws {
    let mover = FakeBackgroundDownloadFileMoving()
    let adapter = makeAdapter(fileMover: mover)
    let destination = makeDestination(identity: .abs(rowID: 6))
    await enqueueFixture(adapter, destination: destination)
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 6),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-6"),
      httpResponse: makeHTTPResponse(statusCode: 401, mimeType: nil, contentLength: nil)
    )

    let event = await iterator.next()
    #expect(event == .authChallenge(identity: .abs(rowID: 6)))
    #expect(mover.moveCalls.isEmpty)
    #expect(await adapter.undeliveredFinishes().isEmpty)
  }

  @Test("a finish stays undelivered until the coordinator acknowledges it")
  func finishStaysUndeliveredUntilAcknowledged() async throws {
    let adapter = makeAdapter()
    await enqueueFixture(adapter, destination: makeDestination(identity: .rss(rowID: 7)))

    adapter.handleFinishedDownloading(
      identity: .rss(rowID: 7),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-7"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mpeg", contentLength: 10)
    )

    #expect(await adapter.currentTasks().isEmpty)
    #expect(await adapter.undeliveredFinishes() == [.rss(rowID: 7)])
    await adapter.acknowledgeFinish(identity: .rss(rowID: 7))
    #expect(await adapter.undeliveredFinishes().isEmpty)
  }

  @Test("a finish whose move failed is never reported as undelivered")
  func failedMoveIsNeverUndelivered() async throws {
    let mover = FakeBackgroundDownloadFileMoving()
    mover.errorToThrow = FakeMoveError(message: "disk full")
    let adapter = makeAdapter(fileMover: mover)
    await enqueueFixture(adapter, destination: makeDestination(identity: .abs(rowID: 8)))

    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 8),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-8"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10)
    )

    #expect(await adapter.undeliveredFinishes().isEmpty)
  }

  // MARK: - failure

  /// Byte-level resume is not implemented. The system attaches `NSURLSessionDownloadTaskResumeData`
  /// to some completion errors, but the adapter discards it rather than carry bytes nobody consumes
  /// across the `BackgroundTransferring` boundary. An interrupted transfer restarts.
  @Test("a transport failure reports its NSError domain and code and discards any system resume data")
  func transportFailureReportsErrorDomainAndCodeAndDiscardsResumeData() async throws {
    let adapter = makeAdapter()
    var iterator = adapter.events.makeAsyncIterator()
    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
      userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume-me".utf8)]
    )

    adapter.handleTaskCompletion(identity: .abs(rowID: 9), error: error)

    let event = await iterator.next()
    #expect(
      event
        == .failed(
          identity: .abs(rowID: 9), errorDomain: NSURLErrorDomain,
          errorCode: NSURLErrorNetworkConnectionLost))
  }

  @Test("a completion with no error reports nothing - success already went through the finish path")
  func noErrorCompletionReportsNothing() async throws {
    let adapter = makeAdapter()
    var iterator = adapter.events.makeAsyncIterator()

    adapter.handleTaskCompletion(identity: .abs(rowID: 10), error: nil)
    // A distinguishable sentinel is queued right after. If it is the next event out of the stream,
    // rather than a byproduct of the no-error call above, that call produced nothing of its own.
    adapter.handleProgress(identity: .abs(rowID: 10), receivedBytes: 1, expectedBytes: 1)

    let event = await iterator.next()
    #expect(event == .progress(identity: .abs(rowID: 10), receivedBytes: 1, expectedBytes: 1))
  }

  // MARK: - reattach

  @Test("reattaching with the same session identifier rewires the delegate and emits a task snapshot")
  func reattachRewiresDelegateAndEmitsSnapshot() async throws {
    let sharedSession = FakeBackgroundDownloadSessionProviding()
    sharedSession.pendingTasksToReturn = [FakeBackgroundDownloadTaskHandle(taskDescription: "42")]
    let capturedDelegates = Locked<[ObjectIdentifier]>([])
    let factory: BackgroundDownloadSessionFactory = { _, delegate, _ in
      capturedDelegates.withValue { $0.append(ObjectIdentifier(delegate as AnyObject)) }
      return sharedSession
    }

    let firstAdapter = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session",
      fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory
    )
    let secondAdapter = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session",
      fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory
    )

    #expect(capturedDelegates.value.count == 2)
    #expect(capturedDelegates.value[0] == ObjectIdentifier(firstAdapter))
    #expect(capturedDelegates.value[1] == ObjectIdentifier(secondAdapter))
    #expect(capturedDelegates.value[0] != capturedDelegates.value[1])

    let snapshots = await secondAdapter.currentTasks()
    #expect(snapshots == [BackgroundTransferSnapshot(identity: .abs(rowID: 42))])
  }

  @Test("the launch snapshot waits for the session's current task inventory")
  func launchSnapshotRefreshesPendingTasks() async throws {
    let sharedSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: sharedSession)
    sharedSession.pendingTasksToReturn = [
      FakeBackgroundDownloadTaskHandle(taskDescription: "42")
    ]

    let snapshots = await adapter.currentTasks()

    #expect(snapshots == [BackgroundTransferSnapshot(identity: .abs(rowID: 42))])
  }

  @Test("reattachment restores the durable destination before a finish callback arrives")
  func reattachmentRestoresDestination() async throws {
    let sharedSession = FakeBackgroundDownloadSessionProviding()
    let factory: BackgroundDownloadSessionFactory = { _, _, _ in sharedSession }
    let firstAdapter = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session",
      fileMover: FakeBackgroundDownloadFileMoving(),
      sessionFactory: factory
    )
    let destination = makeDestination(identity: .abs(rowID: 42))
    await enqueueFixture(firstAdapter, destination: destination)
    sharedSession.pendingTasksToReturn = sharedSession.madeTasks

    let reattachedMover = FakeBackgroundDownloadFileMoving()
    let reattachedAdapter = BackgroundDownloadSessionAdapter(
      sessionIdentifier: "test.session",
      fileMover: reattachedMover,
      sessionFactory: factory
    )

    reattachedAdapter.handleFinishedDownloading(
      identity: .abs(rowID: 42),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/reattached-incoming"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10)
    )

    #expect(reattachedMover.moveCalls.first?.to == destination.destinationURL)
  }

  // MARK: - launch-events completion handler

  @Test("the stored launch-events completion handler is invoked exactly once")
  func launchEventsHandlerInvokedExactlyOnce() async throws {
    let dispatchCallCount = Locked(0)
    let adapter = makeAdapter(mainQueueDispatch: { work in
      dispatchCallCount.withValue { $0 += 1 }
      work()
    })
    let handlerCallCount = Locked(0)
    adapter.storeLaunchEventsCompletionHandler { handlerCallCount.withValue { $0 += 1 } }

    adapter.handleSessionFinishedEvents()
    adapter.handleSessionFinishedEvents()

    #expect(dispatchCallCount.value == 1)
    #expect(handlerCallCount.value == 1)
  }

  @Test("the default launch-events dispatch runs the handler on the main queue")
  func defaultDispatchRunsOnMainQueue() async throws {
    let adapter = makeAdapter()

    let ranOnMainThread = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      adapter.storeLaunchEventsCompletionHandler {
        continuation.resume(returning: Thread.isMainThread)
      }
      adapter.handleSessionFinishedEvents()
    }

    #expect(ranOnMainThread)
  }

  // MARK: - teardown

  @Test("teardown invalidates the underlying session and finishes the event stream")
  func teardownInvalidatesCleanly() async throws {
    let fakeSession = FakeBackgroundDownloadSessionProviding()
    let adapter = makeAdapter(session: fakeSession)

    adapter.invalidate()

    #expect(fakeSession.invalidateAndCancelCallCount == 1)
    var iterator = adapter.events.makeAsyncIterator()
    let next = await iterator.next()
    #expect(next == nil)
  }

  // MARK: - no-token canary

  @Test("no token is persisted anywhere in the adapter's own stored state")
  func noTokenPersistedInAdapterState() async throws {
    let request = try await makeAuthorizedDownloadRequest(accessToken: "CANARY-ACCESS-DO-NOT-LEAK")
    let adapter = makeAdapter()

    await adapter.enqueue(request, destination: makeDestination(identity: .abs(rowID: 1)))

    let strings = ownedDebugStrings(of: adapter)
    #expect(strings.contains(where: { $0.contains("CANARY-ACCESS-DO-NOT-LEAK") }) == false)
  }

  // MARK: - background-session wake delivery

  @Test("every finished-events report is counted, with or without a stored handler")
  func finishedSessionEventsAreCounted() async throws {
    let adapter = makeAdapter(mainQueueDispatch: { $0() })
    #expect(adapter.finishedSessionEvents == 0)

    adapter.handleSessionFinishedEvents()
    adapter.storeLaunchEventsCompletionHandler {}
    adapter.handleSessionFinishedEvents()

    #expect(adapter.finishedSessionEvents == 2)
  }

  @Test("the wake waits until the session has finished and every finish is acknowledged")
  func wakeDeliveryWaitsForSessionAndAcknowledgement() async throws {
    let adapter = makeAdapter(mainQueueDispatch: { $0() })
    await enqueueFixture(adapter, destination: makeDestination(identity: .abs(rowID: 3)))
    adapter.handleFinishedDownloading(
      identity: .abs(rowID: 3),
      temporaryFileURL: URL(fileURLWithPath: "/tmp/incoming-3"),
      httpResponse: makeHTTPResponse(statusCode: 200, mimeType: "audio/mp4", contentLength: 10))
    let baseline = adapter.finishedSessionEvents
    let returned = Locked(false)
    let clock = ManualWakeClock()

    let wait = Task {
      await BackgroundDownloadHardware.waitForWakeDelivery(
        sessionEventsFinished: { adapter.finishedSessionEvents > baseline },
        undeliveredFinishes: { await adapter.undeliveredFinishes() },
        timeout: .seconds(10), pollInterval: .milliseconds(5),
        now: { clock.now }, sleep: { await clock.sleep($0) })
      returned.value = true
    }
    // A parked sleep means the wait has checked both conditions and chosen to keep waiting.
    await clock.waitUntilParked(sleeps: 1)
    #expect(returned.value == false, "the session has not finished its events")

    adapter.handleSessionFinishedEvents()
    clock.tick()
    await clock.waitUntilParked(sleeps: 2)
    #expect(returned.value == false, "a finish is still undelivered")

    await adapter.acknowledgeFinish(identity: .abs(rowID: 3))
    clock.tick()
    await wait.value
    #expect(returned.value)
    #expect(clock.sleeps == 2)
  }

  @Test("the wake gives up at its timeout so the system completion is always signalled")
  func wakeDeliveryReturnsAtTimeout() async throws {
    let clock = ManualWakeClock(advancesOnSleep: true)

    await BackgroundDownloadHardware.waitForWakeDelivery(
      sessionEventsFinished: { true },
      undeliveredFinishes: { [.rss(rowID: 1)] },
      timeout: .milliseconds(100), pollInterval: .milliseconds(10),
      now: { clock.now }, sleep: { await clock.sleep($0) })

    // Returning at all is the timeout. Ten polls of 10 ms reaches it, and not before.
    #expect(clock.sleeps == 10)
  }
}

// MARK: - Test helpers

/// The wake wait's clock, driven by hand. Without `advancesOnSleep`, each sleep parks until
/// `tick()` advances time by its interval, so "still waiting" is a parked sleeper. A real sleep
/// could make that check vacuous under load. With `advancesOnSleep`, each sleep advances time
/// at once.
private nonisolated final class ManualWakeClock: @unchecked Sendable {
  private struct State {
    var elapsed: Duration = .zero
    var sleeps = 0
    var parked: (interval: Duration, continuation: CheckedContinuation<Void, Never>)?
  }

  private let origin = ContinuousClock.now
  private let state = Locked(State())
  private let advancesOnSleep: Bool

  init(advancesOnSleep: Bool = false) {
    self.advancesOnSleep = advancesOnSleep
  }

  var now: ContinuousClock.Instant { origin.advanced(by: state.value.elapsed) }
  var sleeps: Int { state.value.sleeps }

  func sleep(_ interval: Duration) async {
    if advancesOnSleep {
      state.withValue {
        $0.sleeps += 1
        $0.elapsed += interval
      }
      return
    }
    await withCheckedContinuation { continuation in
      state.withValue {
        $0.sleeps += 1
        $0.parked = (interval, continuation)
      }
    }
  }

  /// Advances time by the parked sleep's interval and resumes it.
  func tick() {
    let parked = state.withValue { state in
      defer { state.parked = nil }
      if let parked = state.parked { state.elapsed += parked.interval }
      return state.parked
    }
    parked?.continuation.resume()
  }

  func waitUntilParked(sleeps count: Int) async {
    await waitUntil("sleep \(count) parked") {
      let state = self.state.value
      return state.parked != nil && state.sleeps >= count
    }
  }
}

/// The coalescing clock the progress test drives by hand. A `var` captured by `progressNow`'s
/// `@Sendable` closure and then written triggers "mutated after capture". A reference type the
/// closure reads avoids the warning. `@unchecked`: the test writes and the adapter reads on one
/// task, never concurrently.
private nonisolated final class FakeProgressClock: @unchecked Sendable {
  private let nowBox = Locked<TimeInterval>(0)

  var now: TimeInterval {
    get { nowBox.value }
    set { nowBox.withValue { $0 = newValue } }
  }
}

private func makeAdapter(
  session: FakeBackgroundDownloadSessionProviding = FakeBackgroundDownloadSessionProviding(),
  fileMover: BackgroundDownloadFileMoving = FakeBackgroundDownloadFileMoving(),
  progressNow: @escaping @Sendable () -> TimeInterval = {
    ProcessInfo.processInfo.systemUptime
  },
  mainQueueDispatch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
    DispatchQueue.main.async(execute: $0)
  }
) -> BackgroundDownloadSessionAdapter {
  BackgroundDownloadSessionAdapter(
    sessionIdentifier: "test.session",
    fileMover: fileMover,
    sessionFactory: { _, _, _ in session },
    progressNow: progressNow,
    mainQueueDispatch: mainQueueDispatch
  )
}

private func enqueueFixture(_ adapter: BackgroundDownloadSessionAdapter, destination: DownloadDestinationToken) async {
  let request = try! await makeAuthorizedDownloadRequest(accessToken: "fixture-access")
  await adapter.enqueue(request, destination: destination)
}

private func makeDestination(identity: TransferIdentity) -> DownloadDestinationToken {
  DownloadDestinationToken(
    identity: identity,
    destinationURL: URL(fileURLWithPath: "/tmp/downloads/\(identity.rawValue)"))
}

private func makeFeedTransferRequest(expectedBytes: Int64? = nil) -> AuthorizedTransferRequest {
  var request = URLRequest(url: URL(string: "https://feed.example.test/episode.mp3")!)
  request.httpMethod = "GET"
  request.setValue("Bearer feed-secret", forHTTPHeaderField: "Authorization")
  return AuthorizedTransferRequest(
    request: request, expectedMIMEType: "audio/mpeg", expectedBytes: expectedBytes,
    redirectPolicy: .feed, itemID: "feed-item", fileID: "episode-1")
}

private func makeHTTPResponse(
  statusCode: Int, mimeType: String?, contentLength: Int64?, contentRange: String? = nil
) -> HTTPURLResponse {
  var headerFields: [String: String] = [:]
  if let mimeType {
    headerFields["Content-Type"] = mimeType
  }
  if let contentLength {
    headerFields["Content-Length"] = String(contentLength)
  }
  if let contentRange {
    headerFields["Content-Range"] = contentRange
  }
  return HTTPURLResponse(
    url: URL(string: "https://books.example.test/api/items/item-1/file/42/download")!,
    statusCode: statusCode,
    httpVersion: "HTTP/1.1",
    headerFields: headerFields
  )!
}

/// Mints a real `AuthorizedDownloadRequest` the only way an App-target test can: through the
/// ABSApi factory on `ABSClient.production` with a fake token store, projected to the common
/// `AuthorizedTransferRequest` boundary. Minting is a local transform that never touches
/// `ServerRequestGate` or any transport, so no network call is made.
private func makeAuthorizedDownloadRequest(
  accessToken: String, expectedSize: Int = 123_456
) async throws -> AuthorizedTransferRequest {
  let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let tokenStore = InMemoryTokenStore()
  try tokenStore.save(TokenPair(accessToken: accessToken, refreshToken: "refresh-fixture"), for: account)
  let client = ABSClient.production(server: server, tokenStore: tokenStore)
  let download = try FileDownloadRequest(
    itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: expectedSize)
  let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)
  return AuthorizedTransferRequest(
    request: authorized.makeURLRequest(), expectedMIMEType: authorized.expectedMIMEType,
    expectedBytes: Int64(authorized.expectedSize), itemID: authorized.itemID,
    fileID: authorized.fileID)
}

/// Recursively stringifies every value reachable from `adapter`'s own stored properties. Injected
/// collaborators are skipped by label (`session`, `fileMover`, `sessionFactory`,
/// `mainQueueDispatch`, `lock`): external dependencies, and the production `session` is an opaque
/// system object. The canary covers the adapter's own bookkeeping (`stateByIdentity`, the stored
/// completion handler).
private func ownedDebugStrings(of adapter: BackgroundDownloadSessionAdapter) -> [String] {
  let skippedLabels: Set<String> = ["session", "fileMover", "sessionFactory", "mainQueueDispatch", "lock"]
  var strings: [String] = []
  for child in Mirror(reflecting: adapter).children {
    guard let label = child.label, skippedLabels.contains(label) == false else { continue }
    strings.append(contentsOf: allDebugStrings(of: child.value))
  }
  return strings
}

private func allDebugStrings(of value: Any, depth: Int = 0) -> [String] {
  guard depth < 8 else { return [] }
  var strings = [String(describing: value)]
  for child in Mirror(reflecting: value).children {
    strings.append(contentsOf: allDebugStrings(of: child.value, depth: depth + 1))
  }
  return strings
}
