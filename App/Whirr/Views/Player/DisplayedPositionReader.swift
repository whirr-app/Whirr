import AppModel
import SwiftUI

/// Resolves `PlaybackModel.listPositionSeconds` in its own body and hands it to `content`.
///
/// While the identity plays, the position moves about once a minute and re-runs whichever body
/// reads it. A card with a context menu must not be that body (the menu would rebuild while open,
/// pulsing its glass), so this reader keeps the read below the menu.
///
/// A `nil` `persisted` reads nothing, so a card with no listening progress has no dependency on
/// the playhead.
struct DisplayedPositionReader<Content: View>: View {
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let persisted: Double?
  @ViewBuilder let content: (Double?) -> Content

  var body: some View {
    content(
      persisted.map {
        playback.listPositionSeconds(itemID: itemID, episodeID: episodeID, persisted: $0)
      })
  }
}
