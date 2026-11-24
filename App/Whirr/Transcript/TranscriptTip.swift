import AppModel
import SwiftUI
import TipKit

/// The once-only popover on the player's overflow button that introduces Transcript, shown the
/// first time an episode's player offers it. Transcription never starts on its own, so without
/// this the entry is easy to miss. TipKit keeps it to once and retires it when Transcript is
/// chosen.
struct TranscriptTip: Tip {
  static let title = "Transcribe This Episode"
  static let message =
    "Search what was said, catch host-read ads, and mark or unmark ads yourself. "
    + "Transcribing uses a lot of power, so it's best while charging."
  static let symbol = MediaActionCopy.transcript.systemImage

  var title: Text { Text(Self.title) }
  var message: Text? { Text(Self.message) }
  var image: Image? { Image(systemName: Self.symbol) }
}

/// Which feature tip the overflow button carries. Look Back is books-only and Transcript
/// episodes-only, so at most one applies; each only where the menu offers its entry, so a popover
/// never points at a menu without it.
enum PlayerOverflowTip: Equatable {
  case lookBack
  case transcript

  static func choice(includesLookBack: Bool, includesTranscript: Bool) -> PlayerOverflowTip? {
    if includesLookBack { return .lookBack }
    if includesTranscript { return .transcript }
    return nil
  }

  var tip: any Tip {
    switch self {
    case .lookBack: LookBackTip()
    case .transcript: TranscriptTip()
    }
  }
}
