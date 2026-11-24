import AppModel
import Foundation
import PodcastFeeds
import Testing

/// `FeedPreviewProviding`'s fake. Every request is recorded with the credential it carried, then
/// answered from a per-URL stub, the fake-wide stub, or a minimal preview built from the URL.
///
/// Call `hold()` to park each request until the test completes it by URL with
/// `complete(url:with:)`, so a test can interleave two loads or cancel one in flight. A request
/// that was parked and whose task was cancelled meanwhile records its URL in `cancelledURLs` and
/// throws `CancellationError` once it resumes, as the real client would.
public final class FakeFeedPreviewProviding: FeedPreviewProviding, @unchecked Sendable {
  /// One request: the URL and the credential it carried (`nil` for the credential-free overload).
  public struct Call: Sendable, Equatable {
    public let url: URL
    public let credential: PodcastFeedCredential?

    public init(url: URL, credential: PodcastFeedCredential?) {
      self.url = url
      self.credential = credential
    }
  }

  public typealias Outcome = Result<FeedPreview, FeedPreviewError>

  /// Every request, in order, recorded before it is answered or parked.
  public let recorder = CallRecorder<Call>(label: "FakeFeedPreviewProviding requests")

  private let fallback: Locked<Outcome?>
  private let perURL = Locked<[URL: Outcome]>([:])
  private let holds = Locked(false)
  private let gates = Locked<[URL: TestGate<Outcome>]>([:])
  private let cancelled = Locked<[URL]>([])

  /// - Parameter result: what every request returns unless a per-URL stub overrides it. With
  ///   `nil`, a request returns a one-episode preview titled with the URL's last path component.
  public init(result: Outcome? = nil) {
    fallback = Locked(result)
  }

  /// The URLs requested so far, in order.
  public var urls: [URL] { recorder.calls.map(\.url) }

  /// The credential of each request so far, in order.
  public var credentials: [PodcastFeedCredential?] { recorder.calls.map(\.credential) }

  /// How many requests have been made.
  public var requestCount: Int { recorder.count }

  /// The URLs of requests that were cancelled while parked, in the order they resumed.
  public var cancelledURLs: [URL] { cancelled.value }

  /// What every request without its own stub returns from now on.
  public func stubResult(_ result: Outcome) {
    fallback.value = result
  }

  /// What requests for `url` return from now on, ahead of the fake-wide stub.
  public func stubResult(_ result: Outcome, for url: URL) {
    perURL.withValue { $0[url] = result }
  }

  /// Parks every following request until `complete(url:…)`.
  public func hold() {
    holds.value = true
  }

  /// Resumes the requests parked for `url` with `preview`, first waiting until one is parked. The
  /// URL stays held for later requests. Does nothing for a URL never requested.
  public func complete(url: URL, with preview: FeedPreview) async {
    await complete(url: url, with: .success(preview))
  }

  /// Resumes the requests parked for `url` with `outcome`, first waiting until one is parked. The
  /// URL stays held for later requests. Does nothing for a URL never requested.
  public func complete(url: URL, with outcome: Outcome) async {
    guard let gate = gates.value[url] else { return }
    await gate.waitUntilParked()
    gate.releaseParked(outcome)
  }

  /// Resumes every parked request with its own stubbed answer and opens those URLs, so a request
  /// that has not parked yet answers at once.
  public func releaseAll() {
    let snapshot = gates.value
    for (url, gate) in snapshot { gate.release(outcome(for: url)) }
  }

  public func preview(for url: URL) async throws -> FeedPreview {
    try await preview(for: url, credential: nil)
  }

  public func preview(
    for url: URL, credential: PodcastFeedCredential?
  ) async throws -> FeedPreview {
    // The gate exists before the request is visible, so a test that waits for the request and then
    // calls `complete` always finds it.
    let gate = holds.value ? parkingGate(for: url) : nil
    recorder.record(Call(url: url, credential: credential))
    guard let gate else { return try outcome(for: url).get() }
    let resolved = outcome(for: url)
    let released = await gate.pass(otherwise: { resolved })
    if Task.isCancelled {
      cancelled.withValue { $0.append(url) }
      throw CancellationError()
    }
    return try released.get()
  }

  /// Waits, bounded, until `count` requests have been made.
  @discardableResult
  public func waitForRequestCount(_ count: Int) async -> TestWaitOutcome {
    await recorder.waitUntil(count: count)
  }

  private func outcome(for url: URL) -> Outcome {
    if let stubbed = perURL.value[url] { return stubbed }
    if let fallback = fallback.value { return fallback }
    return .success(
      FeedPreview(
        feedURL: url, title: url.lastPathComponent, author: nil, artworkURL: nil,
        synopsis: nil, episodeCount: 1))
  }

  private func parkingGate(for url: URL) -> TestGate<Outcome> {
    gates.withValue { gates in
      if let existing = gates[url] { return existing }
      let created = TestGate<Outcome>(
        label: "FakeFeedPreviewProviding.preview(\(url.lastPathComponent))",
        ignoresCancellation: true)
      created.hold()
      gates[url] = created
      return created
    }
  }
}
