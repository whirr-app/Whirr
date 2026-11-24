import DesignSystem
import SwiftUI

/// The colours the transcript's content marks and primary action wear: the highlight, Scroll to
/// Now, progress, and the filled capsules. The player passes its resolved show pair; the episode
/// card and the show page pass the show's wash accent. Toolbar controls stay `.primary` whatever
/// the host, so the chrome reads the same from every entry point.
struct TranscriptAccent {
  let fill: Color
  let ink: Color

  init(fill: Color, ink: Color) {
    self.fill = fill
    self.ink = ink
  }

  init(_ pair: WhirrAccentPair) {
    self.init(fill: pair.fill.color, ink: pair.ink.color)
  }

  /// A show's wash accent, paired per appearance with an ink that reads on it, or the app's tint
  /// for a cover too grey to yield one.
  static func show(_ accent: Color?) -> TranscriptAccent {
    guard let accent else { return TranscriptAccent(fill: AppChrome.tint, ink: AppChrome.onTint) }
    let colors = legibleAccentColors(for: accent)
    return TranscriptAccent(fill: colors.fill, ink: colors.ink)
  }
}

extension View {
  /// The app's primary capsule, as item detail draws Play: the show's colour with legible ink.
  func transcriptPrimaryAction(
    _ accent: TranscriptAccent, size: ControlSize = .large
  ) -> some View {
    tint(accent.fill)
      .foregroundStyle(accent.ink)
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
      .controlSize(size)
  }
}
