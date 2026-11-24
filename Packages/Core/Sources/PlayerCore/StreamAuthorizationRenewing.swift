/// Re-mints the credentials the engine's stream resources are fetched with, for whatever item
/// is currently loaded.
///
/// PlayerCore never sees a URL, token or stream resource (ARCHITECTURE.md §4; hence
/// `AVQueuePlayerAudioEngine.configure(tracks:)` sits outside `AudioEngine`), so it only decides
/// when to renew: after an engine failure the adapter classified as authentication. The App-side
/// conformance, which stamped the credentials originally, forces one token refresh, re-stamps the
/// loaded item's tracks and pushes them into the engine before this call returns.
///
/// One attempt then stop is `PlayerController`'s policy, mirroring
/// `DownloadCoordinator.handleAuthChallenge`: never a refresh loop. A renewal that cannot produce
/// credentials has already raised recovery through its own transport, so `false` is complete.
public protocol StreamAuthorizationRenewing: Sendable {
  /// `true` when fresh credentials are in place and a reload is worth attempting.
  func renewStreamAuthorizationAndReconfigure() async -> Bool
}
