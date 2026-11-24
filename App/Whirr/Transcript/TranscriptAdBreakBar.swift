import AppModel
import SwiftUI

/// Which control the transcript's bottom bar holds. One bar, two uses: search's matches while a
/// search has them, the ad breaks otherwise, so checking the ads is a step away from any reading.
nonisolated enum TranscriptBottomBar: Equatable {
  case search
  case adBreaks
  case none

  /// `hasMatches` is false while marking, which hides search's stepping but not the breaks':
  /// marking is where the listener goes from one break to the next.
  static func content(hasMatches: Bool, breakCount: Int) -> Self {
    if hasMatches { return .search }
    return breakCount > 0 ? .adBreaks : .none
  }
}

/// Steps the transcript between ad breaks, to check what was skipped and mark what was missed
/// beside it. It scrolls the text only: playing would start the ad being checked.
nonisolated enum TranscriptAdBreakBar {
  static func title(current: Int?, count: Int) -> String {
    if let current { return "Break \(current + 1) of \(count)" }
    return count == 1 ? "1 Ad Break" : "\(count) Ad Breaks"
  }
}

struct TranscriptAdBreakToolbar: ToolbarContent {
  let model: EpisodeTranscriptModel

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .bottomBar) {
      Button("Previous Ad Break", systemImage: "chevron.up") { model.previousAdBreak() }
        .tint(.primary)
      Text(TranscriptAdBreakBar.title(current: model.currentAdBreak, count: model.adBreaks.count))
        .font(.footnote.monospacedDigit())
      Button("Next Ad Break", systemImage: "chevron.down") { model.nextAdBreak() }
        .tint(.primary)
    }
  }
}
