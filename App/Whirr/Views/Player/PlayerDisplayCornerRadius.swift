import UIKit

/// The radius the moving player page takes: the window's own corner radius, measured, so a page
/// pulled from an edge matches the screen's clip (square iPad windows correctly measure 0). UIKit
/// has no public display-radius property, so a probe filling the window with
/// `.containerConcentric()` corners is read back through `effectiveRadius(corner:)`; it is added
/// and removed synchronously, never drawn.
@MainActor
final class PlayerDisplayCornerRadius {
  static let shared = PlayerDisplayCornerRadius(
    fallback: ExpandedPlayerHostPresentation.inMotionCornerRadius,
    measure: PlayerDisplayCornerRadius.measureConcentric(in:))

  /// The measuring view. A named type only so a test can prove none is left in the window.
  final class Probe: UIView {}

  private struct Key: Hashable {
    let window: ObjectIdentifier
    let size: CGSize

    func hash(into hasher: inout Hasher) {
      hasher.combine(window)
      hasher.combine(size.width)
      hasher.combine(size.height)
    }
  }

  private let fallback: CGFloat
  private let measure: (UIWindow) -> CGFloat?
  private var cache: [Key: CGFloat] = [:]
  /// Windows come and go (iPad scenes, test hosts); a handful of keys is plenty.
  private let cacheLimit = 8

  init(fallback: CGFloat, measure: @escaping (UIWindow) -> CGFloat?) {
    self.fallback = fallback
    self.measure = measure
  }

  /// The radius for a page in `window`, or the fallback constant when there is no window or the
  /// measurement is unusable. An unusable answer is not cached, so the next transition retries.
  func radius(for window: UIWindow?) -> CGFloat {
    guard let window else { return fallback }
    let key = Key(window: ObjectIdentifier(window), size: window.bounds.size)
    if let cached = cache[key] { return cached }
    guard let measured = measure(window), measured.isFinite, measured >= 0 else {
      return fallback
    }
    if cache.count >= cacheLimit { cache.removeAll() }
    cache[key] = measured
    return measured
  }

  /// Reads the top corners: they are the ones a pull-down reveals.
  static func measureConcentric(in window: UIWindow) -> CGFloat? {
    let probe = Probe(frame: window.bounds)
    probe.isUserInteractionEnabled = false
    probe.isHidden = true
    probe.cornerConfiguration = .corners(radius: .containerConcentric())
    window.addSubview(probe)
    defer { probe.removeFromSuperview() }
    probe.layoutIfNeeded()
    return probe.effectiveRadius(corner: [.topLeft, .topRight])
  }
}
