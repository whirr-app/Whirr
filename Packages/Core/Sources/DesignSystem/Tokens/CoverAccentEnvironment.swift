import SwiftUI

/// The player's live accent colour, derived from the current cover art. Threaded through the
/// environment so every control inside the player, sheets included, tints from one value instead
/// of the system blue `Color.accentColor` resolves to. The default is a warm neutral (not blue)
/// for the moments before a cover has resolved a colour of its own.
private struct CoverAccentKey: EnvironmentKey {
  static let defaultValue = WhirrColorToken.neutralCoverAccent.color
}

extension EnvironmentValues {
  public var coverAccent: Color {
    get { self[CoverAccentKey.self] }
    set { self[CoverAccentKey.self] = newValue }
  }
}
