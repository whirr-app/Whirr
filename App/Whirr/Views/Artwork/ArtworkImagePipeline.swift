import ABSApi
import CoreSupport
import Foundation
import UIKit

nonisolated protocol ArtworkByteReading: Sendable {
  func data(for key: ArtworkKey) async -> Data?
}

extension CoverImageClient: ArtworkByteReading {}
extension ProviderArtworkClient: ArtworkByteReading {}

/// Why an artwork request ended, not just what it produced. Only a completed fetch that proved the
/// item has no usable artwork may promote the placeholder to its generated cover. A transport
/// failure (offline, above all) says nothing about whether the artwork exists, and must leave the
/// quiet placeholder (or an existing seed) alone.
enum ArtworkFetchOutcome: Sendable {
  case image(UIImage)
  case unavailable
  case failed

  var image: UIImage? {
    guard case .image(let image) = self else { return nil }
    return image
  }
}

#if DEBUG
  /// `WHIRRART` device trace: why an artwork request ended without an image.
  ///
  /// The lock screen's cover is decided after playback starts, with no debugger attached, so
  /// "no cover", "transfer failed" and "won't decode" need a trace. Carries a local item id and
  /// pixel width, never a URL, token or bytes (see SECURITY.md).
  enum ArtworkTrace {
    /// `nonisolated` because the App module defaults to main-actor isolation and this is called
    /// from inside `ArtworkImagePipeline`, an actor.
    nonisolated static func note(_ event: String, key: ArtworkKey, reason: String) {
      DeviceTraceLog.emit(
        "WHIRRART \(event) item=\(key.itemID) width=\(key.variant.pixelWidth) reason=\(reason)")
    }

    /// A compact token for why a fetch threw. A bare "transport" cannot tell apart a timeout on a
    /// server-side resize, a 5xx, and a body that is not an image, and each implies a different
    /// fix. Carries status and `URLError` codes only, never a URL, host, token, or byte content
    /// (see SECURITY.md).
    nonisolated static func reason(for error: any Error) -> String {
      switch error {
      case let apiError as APIError:
        switch apiError {
        case .notFound: "notFound"
        case .payloadTooLarge: "payloadTooLarge"
        case .decoding: "notAnImage"
        case .cancelled: "cancelled"
        case .transport: "transport"
        case .serverFailure(let statusCode): "serverFailure-\(statusCode)"
        case .unexpectedStatus(let statusCode): "unexpectedStatus-\(statusCode)"
        default: "api-\(apiError)"
        }
      case let urlError as URLError:
        urlError.code == .timedOut ? "timedOut" : "urlError-\(urlError.code.rawValue)"
      case is CancellationError:
        "cancelled"
      default:
        "unknown"
      }
    }
  }
#endif

/// Whether any scroll surface is moving, for artwork work that must not run mid-scroll.
///
/// Not `@Observable` and never read from a `body`: phase changes arrive several times per fling
/// and would re-evaluate every cover. `CoverImageView` reads it in its `.task` on the main actor,
/// before any actor hop, so a suppressed revalidation costs no suspension.
/// `ArtworkImagePipeline` can't host it (an actor read needs the hop being avoided). Callers push
/// a resolved aggregate, not a `ScrollPhase`, so the phase-to-motion mapping lives per screen
/// family.
@MainActor
final class ArtworkScrollActivity {
  static let shared = ArtworkScrollActivity()

  private var movingSources: Set<String> = []

  var isScrolling: Bool { movingSources.isEmpty == false }

  /// Several scroll surfaces are alive at once (Home's outer list and one of its shelves, or a
  /// Library grid behind a presented sheet), so the question is whether every source is idle, not
  /// what the last callback to arrive said.
  func setScrolling(_ isScrolling: Bool, source: String) {
    if isScrolling {
      movingSources.insert(source)
    } else {
      movingSources.remove(source)
    }
  }

  /// Releases every source at once. A tab switched away mid-deceleration may never deliver an
  /// idle phase, and a source left standing would suppress revalidation until that surface was
  /// scrolled again.
  func retireAllScrollSources() {
    movingSources.removeAll(keepingCapacity: true)
  }
}

/// Joins transport and display preparation into one App-side operation per artwork key.
/// Each concrete provider independently retains its source-specific transfer ceiling.
actor ArtworkImagePipeline {
  static let shared = ArtworkImagePipeline()

  /// A shared operation plus the set of live subscribers waiting on it. Subscribers are tracked by
  /// token rather than by count so a release cannot be applied twice: a cancelled subscriber is
  /// released from its cancellation handler and again when the shared task returns, and
  /// `Set.remove` makes the second a no-op.
  private struct InFlight {
    let task: Task<ArtworkFetchOutcome, Never>
    var subscribers: Set<UUID>
  }

  private struct RevalidationInFlight {
    let task: Task<UIImage?, Never>
    var subscribers: Set<UUID>
  }

  private let cache: any PreparedArtworkCaching
  private let decoder: any CoverImageDecoding
  private var inFlight: [ArtworkKey: InFlight] = [:]
  private var revalidationInFlight: [ArtworkKey: RevalidationInFlight] = [:]

  init(
    cache: any PreparedArtworkCaching = PreparedArtworkCache.shared,
    decoder: any CoverImageDecoding = UtilityCoverImageDecoder()
  ) {
    self.cache = cache
    self.decoder = decoder
  }

  /// The image alone, for callers that treat every non-image ending the same way.
  func image(
    for key: ArtworkKey,
    priority: ArtworkPriority,
    client: any ArtworkDataFetching
  ) async -> UIImage? {
    await outcome(for: key, priority: priority, client: client).image
  }

  func outcome(
    for key: ArtworkKey,
    priority: ArtworkPriority,
    client: any ArtworkDataFetching
  ) async -> ArtworkFetchOutcome {
    if let prepared = cache.image(for: key) {
      // Prepared bytes are the first-frame answer. A caller that needs fresh RSS bytes joins the
      // separate revalidation entry, so a warm consumer never waits here.
      return .image(prepared)
    }

    let token = UUID()
    let task = joinOrStart(key: key, priority: priority, client: client, token: token)

    return await withTaskCancellationHandler {
      let result = await task.value
      release(key: key, token: token, cancelling: false)
      return result
    } onCancel: {
      Task { await self.release(key: key, token: token, cancelling: true) }
    }
  }

  /// Revalidates a prepared entry without delaying its first-frame use. The client's byte snapshot
  /// bounds replacement: a conditional 304, or a 200 carrying the same bytes, does not decode or
  /// rewrite the prepared cache. Callers for one key share the same conditional fetch and decode.
  func revalidate(
    for key: ArtworkKey,
    priority: ArtworkPriority,
    client: any ArtworkServing
  ) async -> UIImage? {
    let token = UUID()
    let task = joinOrStartRevalidation(
      key: key, priority: priority, client: client, token: token)

    return await withTaskCancellationHandler {
      let result = await task.value
      releaseRevalidation(key: key, token: token, cancelling: false)
      return result
    } onCancel: {
      Task { await self.releaseRevalidation(key: key, token: token, cancelling: true) }
    }
  }

  /// Returns the key alongside the image: the caller needs to know which variant it got to discard
  /// the seed when the item changes, and probing the cache for a matching identity fails under the
  /// memory pressure that makes a seed worth having.
  func seedImage(
    candidates: [ArtworkKey],
    byteReader: any ArtworkByteReading
  ) async -> (image: UIImage, key: ArtworkKey)? {
    for candidate in candidates {
      guard Task.isCancelled == false else { return nil }

      if let prepared = cache.image(for: candidate) {
        return (prepared, candidate)
      }

      guard let data = await byteReader.data(for: candidate) else { continue }
      guard Task.isCancelled == false else { return nil }
      guard
        let image = await decoder.decodedImage(
          from: data, priority: .visible, shortSidePixelLimit: candidate.variant.pixelWidth
        ).image
      else { continue }
      guard Task.isCancelled == false else { return nil }

      cache.insert(image, for: candidate)
      return (image, candidate)
    }
    return nil
  }

  /// How many live subscribers share `key`'s operation. For the tests: whether two callers joined
  /// the same operation cannot be read off a decode count, because a caller that has not joined yet
  /// leaves that count where a coalesced one does.
  func subscriberCount(for key: ArtworkKey) -> Int {
    inFlight[key]?.subscribers.count ?? 0
  }

  func revalidationSubscriberCount(for key: ArtworkKey) -> Int {
    revalidationInFlight[key]?.subscribers.count ?? 0
  }

  private func joinOrStart(
    key: ArtworkKey,
    priority: ArtworkPriority,
    client: any ArtworkDataFetching,
    token: UUID
  ) -> Task<ArtworkFetchOutcome, Never> {
    if var existing = inFlight[key] {
      existing.subscribers.insert(token)
      inFlight[key] = existing
      return existing.task
    }

    let cache = self.cache
    let decoder = self.decoder
    let taskPriority: TaskPriority =
      priority >= .visible ? .userInitiated : (priority == .scrollPrefetch ? .utility : .background)
    let operation: Task<ArtworkFetchOutcome, Never> = Task(priority: taskPriority) {
      guard Task.isCancelled == false else { return .failed }
      let result: CoverImageResult
      do {
        result = try await client.fetch(key)
      } catch {
        // Only the server answering "there is no cover here" is evidence about the item. Every
        // other ending (offline, a timeout, a 5xx, a cancellation) is evidence about this attempt,
        // and the caller must be free to keep waiting or keep a seed on screen.
        let missing = (error as? APIError) == .notFound
        #if DEBUG
          ArtworkTrace.note(
            missing ? "unavailable" : "failed", key: key,
            reason: ArtworkTrace.reason(for: error))
        #endif
        return missing ? .unavailable : .failed
      }
      // Decode is the expensive half, and a scroll that has moved past this row has no use for
      // the result. Without this check an abandoned prefetch still decodes and keeps the device
      // hot after scrolling stops.
      guard Task.isCancelled == false else { return .failed }
      // Bytes that arrived but will not decode are as good as no artwork: the transfer is paid
      // for and repeating it cannot produce a different image. A cancelled decode is the opposite
      // (evidence about this attempt, never the item), so `CoverImageDecoding` reports the two
      // endings separately rather than collapsing them into one nil.
      let decoded = await decoder.decodedImage(
        from: result.data, priority: priority, shortSidePixelLimit: key.variant.pixelWidth)
      switch decoded {
      case .image(let image):
        cache.insert(image, for: key)
        return .image(image)
      case .undecodable:
        #if DEBUG
          ArtworkTrace.note("unavailable", key: key, reason: "undecodable")
        #endif
        return .unavailable
      case .cancelled:
        return .failed
      }
    }
    inFlight[key] = InFlight(task: operation, subscribers: [token])
    return operation
  }

  private func joinOrStartRevalidation(
    key: ArtworkKey,
    priority: ArtworkPriority,
    client: any ArtworkServing,
    token: UUID
  ) -> Task<UIImage?, Never> {
    if var existing = revalidationInFlight[key] {
      existing.subscribers.insert(token)
      revalidationInFlight[key] = existing
      return existing.task
    }

    let cache = self.cache
    let decoder = self.decoder
    let taskPriority: TaskPriority =
      priority >= .visible ? .userInitiated : (priority == .scrollPrefetch ? .utility : .background)
    let operation: Task<UIImage?, Never> = Task(priority: taskPriority) {
      guard Task.isCancelled == false else { return nil }
      guard await client.needsRefresh(key) else { return nil }
      guard Task.isCancelled == false else { return nil }
      let previousData = await client.data(for: key)
      guard Task.isCancelled == false else { return nil }

      let result: CoverImageResult
      do {
        result = try await client.fetch(key)
      } catch {
        return nil
      }
      guard Task.isCancelled == false, result.data != previousData else { return nil }
      guard
        let image = await decoder.decodedImage(
          from: result.data, priority: priority, shortSidePixelLimit: key.variant.pixelWidth
        ).image
      else {
        return nil
      }
      guard Task.isCancelled == false else { return nil }
      cache.insert(image, for: key)
      return image
    }
    revalidationInFlight[key] = RevalidationInFlight(task: operation, subscribers: [token])
    return operation
  }

  /// Drops one subscriber, cancelling the shared operation only once the last one has gone away.
  private func release(key: ArtworkKey, token: UUID, cancelling: Bool) {
    guard var entry = inFlight[key] else { return }
    entry.subscribers.remove(token)
    guard entry.subscribers.isEmpty else {
      inFlight[key] = entry
      return
    }
    if cancelling {
      entry.task.cancel()
    }
    inFlight[key] = nil
  }

  private func releaseRevalidation(key: ArtworkKey, token: UUID, cancelling: Bool) {
    guard var entry = revalidationInFlight[key] else { return }
    entry.subscribers.remove(token)
    guard entry.subscribers.isEmpty else {
      revalidationInFlight[key] = entry
      return
    }
    if cancelling {
      entry.task.cancel()
    }
    revalidationInFlight[key] = nil
  }
}
