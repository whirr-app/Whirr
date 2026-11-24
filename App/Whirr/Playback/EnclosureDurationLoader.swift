@preconcurrency import AVFoundation
import AppModel

/// Measures a device-owned podcast episode's real duration from its enclosure, for feeds that
/// declare none. In the App target because no `Packages/Core` module imports a media framework;
/// `RSSEpisodeDurationResolver` owns the policy. No headers: an enclosure is a foreign origin and
/// none of the app's credentials belong on one (SECURITY.md §Credentials).
struct AVAssetEnclosureDurationLoader: EnclosureDurationLoading {
  func loadDuration(for enclosureURL: URL) async throws -> Double? {
    let asset = AVURLAsset(url: enclosureURL)
    do {
      let duration = try await asset.load(.duration)
      guard duration.isValid, duration.isIndefinite == false else { return nil }
      let seconds = CMTimeGetSeconds(duration)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    } catch {
      // A cancelled load surfaces as AVFoundation's own error rather than `CancellationError`, and
      // the resolver's contract distinguishes "we gave up" from "this episode has no measurable
      // duration". Re-checking the task settles which of the two happened; every other failure
      // (an unreachable host, a body that is not media) is a plain unknown, not an error to raise.
      try Task.checkCancellation()
      return nil
    }
  }
}
