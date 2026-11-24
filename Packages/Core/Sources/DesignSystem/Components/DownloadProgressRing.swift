import SwiftUI

/// A compact determinate circular indicator for a download control. The track stays visible against
/// Liquid Glass, the filled arc grows clockwise from the top, and the glyph keeps the control
/// meaningful before the first measurable bytes arrive.
///
/// Shared by the item detail bubble and the podcast episode card, so the two cannot disagree about
/// what "half downloaded" looks like.
public struct DownloadProgressRing: View {
  public let progressFraction: Double
  public let systemImage: String?

  /// The animation is explicitly disabled when Reduce Motion is enabled in the environment.
  public static let respectsReducedMotion = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(progressFraction: Double, systemImage: String?) {
    self.progressFraction = progressFraction
    self.systemImage = systemImage
  }

  public static func resolvedProgress(_ progressFraction: Double) -> Double {
    guard progressFraction.isFinite else { return 0 }
    return min(max(progressFraction, 0), 1)
  }

  public static func progressAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .linear(duration: 0.2)
  }

  private var clampedProgress: Double {
    Self.resolvedProgress(progressFraction)
  }

  public var body: some View {
    ZStack {
      Circle()
        .stroke(.primary.opacity(0.22), lineWidth: 2)

      Circle()
        .trim(from: 0, to: clampedProgress)
        .stroke(.tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        .rotationEffect(.degrees(-90))

      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .padding(1)
    .animation(Self.progressAnimation(reduceMotion: reduceMotion), value: clampedProgress)
  }
}
