import SwiftUI

/// The shared translucent card treatment used by player overlays.
public enum PlayerSurfaceMetrics {
  public static let fillOpacity = 0.055
  public static let cornerRadius: CGFloat = 20
  public static let strokeOpacity = 0.08
  public static let strokeLineWidth: CGFloat = 0.5
}

public struct PlayerSurface<Content: View>: View {
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .background(
        Color.white.opacity(PlayerSurfaceMetrics.fillOpacity),
        in: RoundedRectangle(cornerRadius: PlayerSurfaceMetrics.cornerRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: PlayerSurfaceMetrics.cornerRadius, style: .continuous)
          .stroke(.white.opacity(PlayerSurfaceMetrics.strokeOpacity), lineWidth: PlayerSurfaceMetrics.strokeLineWidth)
      }
  }
}
