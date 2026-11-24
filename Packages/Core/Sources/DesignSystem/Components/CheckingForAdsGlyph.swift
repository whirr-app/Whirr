import SwiftUI

/// Stands in for a downloaded episode's mark while that episode is being checked for ads.
/// Transient: nothing marks an episode once it is checked. The waveform's bars cycle; under
/// Reduce Motion it holds still.
public struct CheckingForAdsGlyph: View {
  /// Follows the downloaded label in what VoiceOver hears.
  public static let accessibilityText = "checking for ads"
  public static let systemImage = "waveform"

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init() {}

  public var body: some View {
    Image(systemName: Self.systemImage)
      .symbolEffect(.variableColor.iterative, options: .repeating, isActive: reduceMotion == false)
  }
}
