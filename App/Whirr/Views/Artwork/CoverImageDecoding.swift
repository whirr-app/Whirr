import ABSApi
import ImageIO
import UIKit

/// Why a decode ended, not just what it produced. `.undecodable` is about the bytes (retrying
/// cannot produce a different image) and is the only ending that may promote a placeholder to
/// generated art. `.cancelled` is about the attempt: a scroll moved on, or the last subscriber
/// left. A bare `UIImage?` would let an abandoned decode feed a "no cover" verdict.
nonisolated enum CoverDecodeOutcome: Sendable {
  case image(UIImage)
  case undecodable
  case cancelled

  var image: UIImage? {
    guard case .image(let image) = self else { return nil }
    return image
  }
}

nonisolated protocol CoverImageDecoding: Sendable {
  /// Decodes `data` into a display-ready bitmap whose shorter side is at most
  /// `shortSidePixelLimit` pixels. The limit is the key's variant width, a no-op for ABS covers
  /// (the server already resized them). It exists for RSS artwork, which arrives at whatever size
  /// the feed published (commonly a 3000 px square) and would otherwise decode larger than the
  /// whole prepared tier.
  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
}

/// Admits work before creating a detached decode task, so fast scrolling cannot create an
/// unbounded burst of simultaneous bitmap decompressions.
nonisolated struct UtilityCoverImageDecoder: CoverImageDecoding {
  static let sharedAdmission = CoverDecodeAdmission(maximumConcurrent: 3)

  private let admission: CoverDecodeAdmission

  init(admission: CoverDecodeAdmission = UtilityCoverImageDecoder.sharedAdmission) {
    self.admission = admission
  }

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    do {
      try await admission.acquire(priority: priority)
    } catch {
      // `acquire` throws only `CancellationError`, and it does so without taking a permit.
      return .cancelled
    }
    guard Task.isCancelled == false else {
      await admission.release(priority: priority)
      return .cancelled
    }
    let taskPriority: TaskPriority = priority >= .visible ? .userInitiated : .utility
    let task: Task<UIImage?, Never> = Task.detached(priority: taskPriority) {
      Self.decode(data, shortSidePixelLimit: shortSidePixelLimit)
    }
    let result = await task.value
    await admission.release(priority: priority)
    // The detached decode is not cancellable, so a nil here is always about the bytes.
    return result.map(CoverDecodeOutcome.image) ?? .undecodable
  }

  /// Bounds the bitmap the way the ABS server bounds a cover it is asked for at a width: a
  /// portrait source keeps its shape with its width at the limit, a square source lands exactly on
  /// it, and a landscape source keeps its height at the limit so it still fills a square slot.
  /// Anything already within the limit decodes at its native size, so ABS responses and prepared
  /// cache costs are unchanged.
  nonisolated static func decode(_ data: Data, shortSidePixelLimit: Int) -> UIImage? {
    if let downsampled = downsampledImage(from: data, shortSidePixelLimit: shortSidePixelLimit) {
      return downsampled
    }
    guard let uiImage = UIImage(data: data) else { return nil }
    return prepare(uiImage)
  }

  nonisolated static func prepare(_ uiImage: UIImage) -> UIImage {
    uiImage.preparingForDisplay() ?? uiImage
  }

  /// The longest side ImageIO should produce for a `pixelWidth` × `pixelHeight` source whose
  /// shorter side must not exceed `shortSidePixelLimit`, or nil when the source already fits and
  /// should decode as it is. Rounded up so the shorter side never falls below the limit.
  nonisolated static func downsampledMaxPixelSize(
    pixelWidth: Int, pixelHeight: Int, shortSidePixelLimit: Int
  ) -> Int? {
    let shortSide = min(pixelWidth, pixelHeight)
    guard shortSidePixelLimit > 0, shortSide > shortSidePixelLimit else { return nil }
    let longSide = max(pixelWidth, pixelHeight)
    return Int((Double(longSide) * Double(shortSidePixelLimit) / Double(shortSide)).rounded(.up))
  }

  /// Nil whenever the source fits the limit or ImageIO cannot read it, so the caller falls back to
  /// the plain decode. The thumbnail is created from the full image, never from an embedded
  /// preview, and comes back already decoded.
  private nonisolated static func downsampledImage(
    from data: Data, shortSidePixelLimit: Int
  ) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
      let maxPixelSize = downsampledMaxPixelSize(
        pixelWidth: pixelWidth, pixelHeight: pixelHeight, shortSidePixelLimit: shortSidePixelLimit)
    else { return nil }
    let thumbnailOptions =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }
}

actor CoverDecodeAdmission {
  private struct Waiter {
    let id: UUID
    let priority: ArtworkPriority
    let continuation: CheckedContinuation<Void, Error>
  }

  private let maximumConcurrent: Int
  private let maximumPrefetchConcurrent: Int
  private var active = 0
  private var activePrefetch = 0
  private var waiters: [Waiter] = []

  init(maximumConcurrent: Int) {
    precondition(maximumConcurrent > 0)
    self.maximumConcurrent = maximumConcurrent
    maximumPrefetchConcurrent = max(0, maximumConcurrent - 1)
  }

  var inFlightCount: Int { active }
  var queuedCount: Int { waiters.count }

  func acquire(priority: ArtworkPriority) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard Task.isCancelled == false else {
          continuation.resume(throwing: CancellationError())
          return
        }
        if canAdmit(priority: priority) {
          active += 1
          if priority == .scrollPrefetch {
            activePrefetch += 1
          }
          continuation.resume()
        } else {
          waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  func release(priority: ArtworkPriority) {
    active -= 1
    if priority == .scrollPrefetch {
      activePrefetch -= 1
    }

    guard let index = nextAdmissibleWaiterIndex else { return }
    let waiter = waiters.remove(at: index)
    active += 1
    if waiter.priority == .scrollPrefetch {
      activePrefetch += 1
    }
    waiter.continuation.resume()
  }

  private var nextAdmissibleWaiterIndex: Int? {
    waiters.indices
      .filter { canAdmit(priority: waiters[$0].priority) }
      .min { lhs, rhs in
        if waiters[lhs].priority != waiters[rhs].priority {
          return waiters[lhs].priority > waiters[rhs].priority
        }
        return lhs < rhs
      }
  }

  private func canAdmit(priority: ArtworkPriority) -> Bool {
    guard active < maximumConcurrent else { return false }
    guard priority == .scrollPrefetch else { return true }
    return maximumPrefetchConcurrent == 0 || activePrefetch < maximumPrefetchConcurrent
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
