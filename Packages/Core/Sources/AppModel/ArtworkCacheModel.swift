import Observation
import SyncEngine

/// Observable state for Settings › Downloads › Artwork Cache. Boundary calls are always made from
/// tasks, so construction and body evaluation never wait on the cache directory walk.
@MainActor
@Observable
public final class ArtworkCacheModel {
  /// `nil` until the first measurement lands, which is distinct from a measured zero (what an
  /// emptied cache reports). A screen renders the two differently.
  public private(set) var artworkCacheBytes: Int64?
  public private(set) var isConfirmingClearArtwork = false
  public private(set) var isClearingArtwork = false

  private let access: any ArtworkCacheAccess

  @ObservationIgnored private var clearTask: Task<Void, Never>?

  public init(access: any ArtworkCacheAccess) {
    self.access = access
  }

  deinit {
    clearTask?.cancel()
  }

  /// Measures the cover cache. Kept off construction and body evaluation: it walks a directory.
  public func refreshArtworkCacheSize() async {
    let bytes = await access.artworkCacheBytes()
    guard Task.isCancelled == false else { return }
    if artworkCacheBytes != bytes {
      artworkCacheBytes = bytes
    }
  }

  /// Stages the destructive confirmation.
  public func requestClearArtwork() {
    guard isClearingArtwork == false else { return }
    isConfirmingClearArtwork = true
  }

  public func cancelClearArtwork() {
    isConfirmingClearArtwork = false
  }

  /// Clears from a task, as the boundary does, so the UI event path never awaits boundary I/O.
  /// The size is re-read afterwards: emptying the cache is the only event that can change it while
  /// this screen is open.
  public func confirmClearArtwork() {
    isConfirmingClearArtwork = false
    guard isClearingArtwork == false else { return }
    isClearingArtwork = true

    let access = self.access
    clearTask = Task { [weak self, access] in
      await access.clearArtworkCache()
      guard let self else { return }
      await self.refreshArtworkCacheSize()
      self.isClearingArtwork = false
    }
  }
}
