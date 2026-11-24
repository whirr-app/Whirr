/// The reducer's trim bookkeeping for the loaded episode.
struct TrimState: Sendable {
  var itemID: String?
  var episodeID: String?
  var map: PlayerTrimMap?
}

extension PlayerReducer {
  /// The map in force for the loaded item, or nil when it plays whole. A map applies only to the
  /// item and episode it was sent for, and only to a single-file item, whose file time is its
  /// global time.
  var activeTrimMap: PlayerTrimMap? {
    state.item.flatMap(trimMap(for:))
  }

  func trimMap(for item: PlayerItem) -> PlayerTrimMap? {
    guard item.id == trim.itemID, item.episodeID == trim.episodeID, item.timeline.tracks.count == 1
    else { return nil }
    return trim.map
  }

  /// The position progress reports. A file that opens with a cut starts playing at its end, so a
  /// playhead still there has heard nothing and reports 0; otherwise a reset, or a play paused at
  /// once, would leave the item counted as started.
  var reportedPosition: Double {
    guard let opening = activeTrimMap?.cuts.first, opening.start == 0,
      state.globalPosition <= opening.end
    else { return state.globalPosition }
    return 0
  }

  /// `target` moved out of any cut, as the engine will land it, and kept within the item.
  func trimSnapped(_ target: Double, in item: PlayerItem) -> Double {
    guard let map = trimMap(for: item) else { return target }
    return min(map.snapped(target), item.timeline.totalDuration)
  }

  /// A fresh load replaces the map with the one it carries.
  mutating func resetTrim(for item: PlayerItem, map: PlayerTrimMap?) {
    trim = TrimState(itemID: item.id, episodeID: item.episodeID, map: Self.normalised(map))
  }

  // MARK: - Intents

  mutating func handleSetTrimMap(
    itemID: String, episodeID: String?, map: PlayerTrimMap?, now: Double
  ) -> PlayerStepResult {
    guard let item = state.item, item.id == itemID, item.episodeID == episodeID else { return .none }
    let previous = activeTrimMap
    trim = TrimState(itemID: itemID, episodeID: episodeID, map: Self.normalised(map))
    guard activeTrimMap != previous else { return .none }
    return handleTrimReload(now: now)
  }

  /// Reloads the engine where the listener is, under the new map. Shaped like a cross-track seek
  /// rather than a load: the item, its intent, its skip ranges and its sleep timer all carry on, and
  /// `resolveReady` restores playing or paused when the engine is ready. A terminal or idle item
  /// only keeps the map for later.
  private mutating func handleTrimReload(now: Double) -> PlayerStepResult {
    guard isLegalForPlayheadMovement, let item = state.item else { return .none }
    let clamped = min(max(state.globalPosition, 0), item.timeline.totalDuration)
    let target = trimSnapped(clamped, in: item)
    let (track, localOffset) = item.timeline.trackAndLocalOffset(atGlobalOffset: target)
    state.globalPosition = target
    outstandingSeekTarget = target
    guard let event = checkpoint(now: now, newPhase: .seeking) else { return .none }
    generation += 1
    state.currentTrackIndex = track.index
    return PlayerStepResult(
      effects: [
        .loadEngine(
          track: track, localOffset: localOffset, rate: state.rate, generation: generation, trim: activeTrimMap)
      ],
      progressEvents: [event])
  }

  // MARK: - Engine events

  /// The engine is playing the track whole, so the reducer stops predicting cuts. No reload: what
  /// plays is already right, only the accounting has to follow it.
  mutating func handleTrimDeclined() -> PlayerStepResult {
    trim.map = nil
    return .none
  }

  private static func normalised(_ map: PlayerTrimMap?) -> PlayerTrimMap? {
    guard let map, map.isEmpty == false else { return nil }
    return map
  }
}
