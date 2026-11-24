import AVFoundation
import AppModel
import CoreSupport
import PlayerCore

/// Builds the composition that plays a Trim Silences map and hands it
/// to the engine through `register`. The kept segments are inserted at `PlayerTrimMap.timescale`,
/// the timescale the map's edges are quantised to, so the composition's clock and the map agree.
nonisolated final class CompositionTrimPreparer: PlaybackTrimPreparing {
  private let register: @MainActor (URL, PlayerTrimMap, AVAsset) -> Void

  init(register: @escaping @MainActor (URL, PlayerTrimMap, AVAsset) -> Void) {
    self.register = register
  }

  func prepare(map: PlayerTrimMap, forFileURL url: URL, timing: PlaybackTrimTiming) async -> Bool {
    #if DEBUG
      let started = ContinuousClock.now
    #endif
    let composition = await Self.buildComposition(map: map, fileURL: url, timing: timing)
    #if DEBUG
      DeviceTraceLog.emit(
        "WHIRRTRIM prepare cuts=\(map.cuts.count) trimmed=\(map.totalTrimmed) timing=\(timing) "
          + "ok=\(composition == nil ? 0 : 1) elapsed=\(ContinuousClock.now - started)")
    #endif
    guard let composition else { return false }
    await register(url, map, composition)
    return true
  }

  /// Playback's own options, plus precise timing for a file whose estimated timeline drifts.
  /// Precise timing scans the whole file when the asset loads,
  /// about a quarter of a second for an hour of MP3 on an iPhone 15 Pro, so clean files skip it.
  nonisolated static func sourceOptions(forFileURL url: URL, timing: PlaybackTrimTiming) -> [String: Any] {
    let mimeType = url.pathExtension.lowercased() == "mpeg" ? "audio/mpeg" : nil
    var options = AVFoundationPlayerItemFactory.assetOptions(headers: [:], mimeType: mimeType)
    if timing == .precise {
      options[AVURLAssetPreferPreciseDurationAndTimingKey] = true
    }
    return options
  }

  /// Off the main actor. Returns an immutable copy, so the mutable composition never leaves this
  /// function.
  private nonisolated static func buildComposition(
    map: PlayerTrimMap, fileURL: URL, timing: PlaybackTrimTiming
  ) async -> AVComposition? {
    let source = AVURLAsset(url: fileURL, options: sourceOptions(forFileURL: fileURL, timing: timing))
    do {
      guard let sourceTrack = try await source.loadTracks(withMediaType: .audio).first else {
        return nil
      }
      let duration = try await source.load(.duration)
      guard duration.isValid, duration.isNumeric, duration > .zero else { return nil }

      let scale = PlayerTrimMap.timescale
      let end = duration.convertScale(scale, method: .roundHalfAwayFromZero)
      let composition = AVMutableComposition()
      guard
        let track = composition.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }

      var cursor = CMTime.zero
      var insertAt = CMTime.zero
      func keep(to stop: CMTime) throws {
        guard stop > cursor else { return }
        let range = CMTimeRange(start: cursor, end: stop)
        try track.insertTimeRange(range, of: sourceTrack, at: insertAt)
        insertAt = insertAt + range.duration
      }
      for cut in map.cuts {
        let start = CMTime(value: CMTimeValue((cut.start * Double(scale)).rounded()), timescale: scale)
        let stop = CMTime(value: CMTimeValue((cut.end * Double(scale)).rounded()), timescale: scale)
        try keep(to: min(start, end))
        cursor = max(cursor, min(stop, end))
      }
      try keep(to: end)
      guard insertAt > .zero, let copy = composition.copy() as? AVComposition else { return nil }
      return copy
    } catch {
      return nil
    }
  }
}
