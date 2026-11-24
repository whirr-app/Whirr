import ABSApi
import Foundation
import SyncEngine
import UIKit

nonisolated protocol PreparedArtworkCaching: Sendable {
  func image(for key: ArtworkKey) -> UIImage?
  func insert(_ image: UIImage, for key: ArtworkKey)
  func removeAll()
}

nonisolated extension PreparedArtworkCaching {
  /// Finds an already-decoded fallback without an actor hop. The ordered key is returned with the
  /// image so a view can keep the same identity checks it applies to asynchronously decoded seeds.
  func firstImage(for keys: [ArtworkKey]) -> (image: UIImage, key: ArtworkKey)? {
    for key in keys {
      if let image = image(for: key) { return (image, key) }
    }
    return nil
  }
}

/// A synchronous display-ready tier. `NSCache` is thread-safe, so both scrolling views and
/// background decode work may access it without an actor hop. The unchecked conformance is
/// limited to that documented thread-safe container and immutable key boxes.
nonisolated final class PreparedArtworkCache: PreparedArtworkCaching, ArtworkCacheClearing,
  @unchecked Sendable
{
  /// Sized for the 140-point rung (~313-470 KB each) that the Library grid and Home cards draw:
  /// 64 MiB holds only 140-160, while one browse sweep on a 13-inch iPad touches 436 covers and a
  /// miss costs a decode plus a second body pass mid-scroll. Derived from installed memory (64 MiB
  /// on the smallest devices, a whole sweep on a 16 GB iPad). No correctness role: `RootView`'s
  /// memory-warning handler drops it all and `NSCache` evicts under pressure.
  static let deviceTotalCostLimit = min(
    256 * 1024 * 1024, max(64 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 32)))

  /// Scaled with the cost budget so the limits do not fight: cost binds for the 140-point rung,
  /// while the count ceiling matters for the much smaller compact-row thumbnails, which would
  /// otherwise exhaust it long before the bytes.
  static let deviceCountLimit = 300 * (deviceTotalCostLimit / (64 * 1024 * 1024))

  #if PERF_INVESTIGATION
    /// Overridable in a PERF_INVESTIGATION build only, so a device run can A/B the budget directly
    /// instead of inferring it from the cover ablation, which removes the artwork entirely.
    static let defaultTotalCostLimit =
      ProcessInfo.processInfo.environment["WHIRR_ARTWORK_COST_MIB"].flatMap(Int.init)
      .map { $0 * 1024 * 1024 } ?? deviceTotalCostLimit
    static let defaultCountLimit =
      ProcessInfo.processInfo.environment["WHIRR_ARTWORK_COUNT"].flatMap(Int.init)
      ?? deviceCountLimit
  #else
    static let defaultTotalCostLimit = deviceTotalCostLimit
    static let defaultCountLimit = deviceCountLimit
  #endif

  static let shared = PreparedArtworkCache()

  private let storage = NSCache<ArtworkKeyBox, UIImage>()

  init(
    totalCostLimit: Int = PreparedArtworkCache.defaultTotalCostLimit,
    countLimit: Int = PreparedArtworkCache.defaultCountLimit
  ) {
    storage.totalCostLimit = totalCostLimit
    storage.countLimit = countLimit
  }

  func image(for key: ArtworkKey) -> UIImage? {
    storage.object(forKey: ArtworkKeyBox(key))
  }

  func insert(_ image: UIImage, for key: ArtworkKey) {
    storage.setObject(image, forKey: ArtworkKeyBox(key), cost: Self.cost(of: image))
  }

  func removeAll() {
    storage.removeAllObjects()
  }

  /// The decoded half of a user-triggered artwork clear. Clearing only the transport's compressed
  /// tier would leave every cover already prepared for display still on screen.
  func clearCachedArtwork() async {
    removeAll()
  }

  static func cost(of image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    return cgImage.bytesPerRow * cgImage.height
  }
}

private nonisolated final class ArtworkKeyBox: NSObject {
  let key: ArtworkKey

  init(_ key: ArtworkKey) {
    self.key = key
  }

  override var hash: Int {
    key.hashValue
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? ArtworkKeyBox else { return false }
    return key == other.key
  }
}

/// Holds a cover the synchronous cache served, without being observed.
///
/// `CoverImageView` keeps this in `@State` so it survives body evaluations, but mutates it
/// through the reference so the mutation raises no invalidation. A cache hit must not schedule a
/// second body pass (see the `retained` property).
@MainActor
final class RetainedArtwork {
  var key: ArtworkKey?
  var image: UIImage?
  /// The key the latest body pass drew, or nil. A task hit may skip the observed write only when
  /// this matches: another consumer can fill the cache between body and task, and an undrawn hit
  /// must invalidate or the placeholder stays up.
  var paintedKey: ArtworkKey?

  /// A method rather than an assignment so a body pass can record it as an expression.
  func notePainted(_ key: ArtworkKey?) {
    paintedKey = key
  }

  init() {}
}

/// One cover held for a reader outside the view that has it: the cover a `CoverImageView` drew
/// on its last body pass, or the expanded page's cover as the mini player prepared it.
///
/// The prepared cache empties on backgrounding while the view keeps its image, so readers needing
/// the on-screen picture (the player's open morph) use this. Unobserved, like `RetainedArtwork`.
@MainActor
final class DrawnArtwork {
  private var key: ArtworkKey?
  private var image: UIImage?

  init() {}

  /// Records the finished cover for `key`: the one a body pass drew, or `nil` when it drew a seed
  /// or a placeholder; or the one prepared ahead for the page.
  func note(_ image: UIImage?, for key: ArtworkKey) {
    self.key = key
    self.image = image
  }

  /// The image last recorded for `key`.
  func image(for key: ArtworkKey) -> UIImage? {
    self.key == key ? image : nil
  }
}
