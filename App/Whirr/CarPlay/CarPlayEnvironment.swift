import AppModel
import Foundation
import Persistence
import PlayerCore
import UIKit

/// What the car allows right now. A moving car lowers the item count; the screen sets the rest.
struct CarPlayLimits: Equatable {
  var maximumTabCount: Int
  var maximumItemCount: Int
  /// The longer edge of a row's thumbnail, in pixels.
  var imagePixelSize: Int
  var isDark: Bool
}

/// One account graph, as the car uses it. Every command and read is already bound to the
/// graph's generation, so nothing here can reach the account that replaces it.
struct CarPlayGraph {
  let generation: Int
  var start: () -> Void
  var snapshot: (CarPlayBrowseRoute) -> CarPlayBrowseSnapshot?
  var page: (CarPlayBrowseRoute, CarPlayBrowseCursor?, Int) async -> CarPlayBrowsePageResult
  var perform: (CarPlaySelection) async -> CarPlayPlaybackResult
  var selectChapter: (CarPlayChapterRow, CarPlayChapterList) -> CarPlayPlaybackResult
  var setRate: (Double) -> CarPlayPlaybackResult
  var playerState: () -> PlayerState
  var effectiveRate: (String?) -> Double
  var loadArtwork: CarPlayArtworkRequests<UIImage>.Load
}

/// The coordinator's view of the process: readiness, the current graph and the car's limits.
struct CarPlayEnvironment {
  /// Asks the runtime for a graph; safe to repeat.
  var start: () -> Void
  var rootState: () -> CarPlayRootState
  var graph: () -> CarPlayGraph?
  var presets: () -> [Double]
  var limits: () -> CarPlayLimits
}

extension CarPlayEnvironment {
  static func production(
    runtime: AppRuntime, defaults: UserDefaults = .standard, limits: @escaping () -> CarPlayLimits
  ) -> CarPlayEnvironment {
    CarPlayEnvironment(
      start: { runtime.start() },
      rootState: {
        switch runtime.readiness {
        case .starting: .starting
        case .storageUnavailable: .unlockPhone
        case .failed: .unavailable
        // A graph with no signed-in account has no car lists, and offers none of its old rows.
        case .ready: runtime.carPlayBrowse == nil ? .signedOut : .ready
        }
      },
      graph: {
        guard let composition = runtime.current, let browse = runtime.carPlayBrowse,
          let actions = runtime.carPlayActions
        else { return nil }
        let generation = actions.generation
        let player = composition.environment.dependencies.player
        let rate = composition.root.playbackRate
        return CarPlayGraph(
          generation: generation,
          start: { browse.start() },
          snapshot: { browse.snapshot(for: $0) },
          page: { await browse.page($0, after: $1, generation: generation, pageSize: $2) },
          perform: { selection in
            switch selection {
            case .resumeLastPlayed: await actions.resumeLastPlayed()
            case .play(let identity, let chapter):
              await actions.play(identity: identity, chapter: chapter, generation: generation)
            }
          },
          selectChapter: { row, list in
            actions.selectChapter(
              row.chapter, itemID: list.itemID, episodeID: list.episodeID, generation: list.generation)
          },
          setRate: { actions.setRate($0, generation: generation) },
          playerState: { player.state },
          effectiveRate: { rate.effectiveRate(forItemID: $0) },
          loadArtwork: CarPlayArtworkLoader.load(client: composition.environment.artworkClient))
      },
      presets: {
        PlaybackRatePresetConfiguration.decode(
          defaults.string(forKey: ICloudSettingsSync.playbackRatePresetsKey) ?? ""
        ).rates
      },
      limits: limits)
  }
}
