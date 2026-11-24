import DesignSystem
import SwiftUI

extension View {
  /// The label of a primary play capsule: the episode card's Play and a collection's header
  /// actions share it so they read as the same control.
  func playCapsuleLabel() -> some View {
    font(.headline)
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .padding(.horizontal, WhirrSpacing.small)
      .frame(minHeight: PodcastEpisodeCardViewPresentation.Metric.playButtonMinHeight)
  }
}
