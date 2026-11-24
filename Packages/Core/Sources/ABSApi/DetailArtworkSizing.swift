import Foundation

/// A cover's measured shape and the detail width that was fetched for it.
public struct CoverShape: Sendable, Equatable {
  /// Width ÷ height: a 2:3 book cover is 0.667.
  public let aspectRatio: Double
  /// The pixel width `DetailArtworkSizing` gave for this shape when the bytes were fetched.
  public let fitPixelWidth: Int

  public init(aspectRatio: Double, fitPixelWidth: Int) {
    self.aspectRatio = aspectRatio
    self.fitPixelWidth = fitPixelWidth
  }
}

/// Chooses the width the detail cover is requested at.
///
/// The server resizes by width only, while the detail hero fits its cover inside a square, so a
/// portrait cover asked for at the square's full width fetches undrawn pixels. Given the shape:
///
///     max(heroSide × min(1, aspect), previewEdge × max(1, aspect))
///
/// The hero draws `heroSide × min(1, aspect)` points wide; the context-menu preview card's longest
/// edge is `previewEdge`, needing `previewEdge × max(1, aspect)` of width so a landscape cover
/// keeps `previewEdge` of height. The result never exceeds the no-shape width.
public struct DetailArtworkSizing: Sendable, Equatable {
  /// The display size the detail tier is keyed by when no shape is known.
  public let fallbackDisplaySize: Double
  public let heroSide: Double
  public let previewEdge: Double
  public let displayScale: Double

  public init(
    fallbackDisplaySize: Double, heroSide: Double, previewEdge: Double, displayScale: Double
  ) {
    self.fallbackDisplaySize = fallbackDisplaySize
    self.heroSide = heroSide
    self.previewEdge = previewEdge
    self.displayScale = displayScale
  }

  /// The detail key used when a cover's shape is not known: the same key as before shapes existed.
  public var fallbackVariant: ArtworkVariant {
    .highFidelity(displaySize: fallbackDisplaySize, displayScale: displayScale)
  }

  /// The pixel width a cover of `aspectRatio` needs, capped at the fallback width.
  public func fitPixelWidth(aspectRatio: Double) -> Int {
    let fallback = fallbackVariant.pixelWidth
    guard aspectRatio.isFinite, aspectRatio > 0 else { return fallback }
    let points = max(heroSide * min(1, aspectRatio), previewEdge * max(1, aspectRatio))
    return min(fallback, max(1, Int((points * displayScale).rounded(.up))))
  }

  /// The detail variant for a cover whose shape was measured, or the fallback.
  ///
  /// The fitted variant is used only when the width this sizing gives equals the width recorded
  /// with the shape. That width is the one whose bytes are known to be stored; if the rule or the
  /// display scale has changed since, the fallback keeps the cover on a key that still resolves.
  public func variant(for shape: CoverShape?) -> ArtworkVariant {
    let fallback = fallbackVariant
    guard let shape else { return fallback }
    let width = fitPixelWidth(aspectRatio: shape.aspectRatio)
    guard width == shape.fitPixelWidth, width < fallback.pixelWidth else { return fallback }
    return .detailFit(pixelWidth: width)
  }
}

/// Every measured cover shape, readable synchronously from any thread.
///
/// A view building a detail key cannot wait on the database, so the table is held in memory:
/// loaded when the account is composed, updated by the bulk cover pass. A shape answers only for
/// the revision it was measured at.
public final class CoverShapeIndex: @unchecked Sendable {
  private struct Entry {
    let revision: ArtworkRevision
    let shape: CoverShape
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  public init() {}

  public func shape(itemID: String, revision: ArtworkRevision) -> CoverShape? {
    lock.withLock {
      guard let entry = entries[itemID], entry.revision == revision else { return nil }
      return entry.shape
    }
  }

  public func record(_ shape: CoverShape, itemID: String, revision: ArtworkRevision) {
    lock.withLock { entries[itemID] = Entry(revision: revision, shape: shape) }
  }

  public func removeAll() {
    lock.withLock { entries.removeAll() }
  }
}
