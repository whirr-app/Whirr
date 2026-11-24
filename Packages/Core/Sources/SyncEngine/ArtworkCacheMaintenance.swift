import ABSApi
import Foundation

/// One store of artwork bytes a user-triggered clear must empty. There is more than one: the
/// transport's compressed tier and the App's decoded-image cache both answer for the
/// same cover, so clearing only the first leaves the covers already on screen unchanged.
public protocol ArtworkCacheClearing: Sendable {
  func clearCachedArtwork() async
}

extension CoverImageClient: ArtworkCacheClearing {}

/// The Artwork Cache screen's on-device accounting and clear. It measures the bytes the covers
/// occupy rather than how many items have one.
public protocol ArtworkCacheMaintaining: Sendable {
  func cachedByteSize() async -> Int64
  func clear() async
}

/// The inert default, so `ArtworkCacheService` composes without a wired cover cache.
public struct NoOpArtworkCacheMaintenance: ArtworkCacheMaintaining, Sendable {
  public init() {}

  public func cachedByteSize() async -> Int64 { 0 }

  public func clear() async {}
}

/// Measures the disposable cover cache by walking its directory, and clears it through the caches
/// that own the bytes rather than by deleting files underneath them.
///
/// The RSS half is a `URLCache`, but reading `currentDiskUsage` leaves the macOS host test process
/// unable to exit, so the walk is used instead. A few thousand cache files cost single-digit
/// milliseconds, off the caller's actor.
public struct DiskArtworkCacheMaintenance: ArtworkCacheMaintaining, Sendable {
  /// A nil entry means composition got no directory for that cache: nothing to measure, but the
  /// clear still runs (each participant owns its store).
  private let directoryURLs: [URL?]
  private let clearing: [any ArtworkCacheClearing]

  public init(directoryURL: URL?, clearing: [any ArtworkCacheClearing]) {
    directoryURLs = [directoryURL]
    self.clearing = clearing
  }

  /// Measures each disposable artwork directory. The cover and RSS transports own separate
  /// stores, so Settings must account for both to report the bytes its clear removes.
  public init(directoryURLs: [URL?], clearing: [any ArtworkCacheClearing]) {
    self.directoryURLs = directoryURLs
    self.clearing = clearing
  }

  public func cachedByteSize() async -> Int64 {
    let directories = directoryURLs
    return await Task.detached(priority: .utility) {
      directories.reduce(into: Int64(0)) { total, directoryURL in
        if let directoryURL {
          total += Self.byteSize(of: directoryURL)
        }
      }
    }.value
  }

  /// Each participant empties its own store: the cover client owns the bytes under
  /// `directoryURL` and the decoded cache owns its images, so neither is reached by deleting
  /// files from here.
  public func clear() async {
    for participant in clearing {
      await participant.clearCachedArtwork()
    }
  }

  /// Allocated size rather than logical size: it is what the cache costs the device, and matches
  /// Settings' own storage reporting. A directory that does not exist yet (a cold launch before
  /// the first cover) counts as zero.
  private static func byteSize(of directory: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles])
    else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else { continue }
      let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
      total += Int64(bytes)
    }
    return total
  }
}
