import ABSApi
import Foundation
import PlayerCore
import SyncEngine

/// Decorates the real `PlaybackSyncing` conformance (`PlaybackSessionCoordinator`) to satisfy
/// `AVQueuePlayerAudioEngine.configure(tracks:)`'s contract: the caller owning credentialed access
/// to `PreparedPlayback` supplies resolved URLs out of band from the `AudioEngine` protocol,
/// before any `load`. SyncEngine must never see AVFoundation or a stream URL (ARCHITECTURE.md),
/// so this stays in the App target. Forwards everything unchanged except `startSession` and local
/// promotion, which also configure the engine's track URLs before the matching `.load`.
final class StreamConfiguringPlaybackSyncing: PlaybackSyncing, StreamAuthorizationRenewing, @unchecked Sendable {
  private let underlying: any PlaybackSyncing
  private let engine: AVQueuePlayerAudioEngine
  /// The last configured session's tracks, so a renewal can re-stamp them. Only the credential
  /// changes: a direct-play `/api/items/{id}/file/{ino}` is item-scoped, so the URLs stay valid.
  /// Main-actor isolated, touched only where `engine.configure(tracks:)` already hops there, so it
  /// stays in step with the engine's resource table.
  @MainActor private var lastConfiguredTracks: [PreparedPlaybackTrack] = []

  init(underlying: any PlaybackSyncing, engine: AVQueuePlayerAudioEngine) {
    self.underlying = underlying
    self.engine = engine
  }

  func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    let prepared = try await underlying.startSession(itemID: itemID, episodeID: episodeID)
    // Authorization is decided per resource, never once per session (API-CONVENTIONS.md). A
    // direct-play `/api/items/{id}/file/{ino}` answers `401` unauthenticated and needs the stamped
    // Bearer; a transcoded `/hls/{sessionId}/output.m3u8` is mounted outside the `/api` middleware
    // and must not receive one; a local app-container file URL needs no headers.
    // `PlaybackStreamAuthorization` owns the decision; this asks it once per track.
    let authorization = prepared.streamAuthorization
    let resources = prepared.tracks.map {
      PlaybackTrackResource(
        trackIndex: $0.index,
        url: $0.url,
        headers: authorization?.httpHeaderFields(for: $0.url) ?? [:],
        mimeType: $0.mimeType)
    }
    await MainActor.run {
      lastConfiguredTracks = prepared.tracks
      engine.configure(tracks: resources)
    }
    return prepared
  }

  func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
  ) async -> PreparedPlayback? {
    guard
      let prepared = await underlying.promoteStreamingSessionToLocalDownload(
        itemID: itemID, episodeID: episodeID, currentPosition: currentPosition,
        streamedDuration: streamedDuration)
    else { return nil }

    // Keep promotion on the same configuration path as startSession. The promoted preparation is
    // local, so its file URLs never need stream authorization; the shared per-track mapping below
    // therefore supplies empty headers while still replacing the engine's resource table.
    let authorization = prepared.streamAuthorization
    let resources = prepared.tracks.map {
      PlaybackTrackResource(
        trackIndex: $0.index,
        url: $0.url,
        headers: authorization?.httpHeaderFields(for: $0.url) ?? [:],
        mimeType: $0.mimeType)
    }
    await MainActor.run {
      lastConfiguredTracks = prepared.tracks
      engine.configure(tracks: resources)
    }
    return prepared
  }

  func stopSession() async throws {
    try await underlying.stopSession()
  }

  func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    try await underlying.renewStreamAuthorization()
  }

  /// `StreamAuthorizationRenewing` (PlayerCore): the engine reported an authentication failure, so
  /// re-mint the stream credentials and push the same track URLs back into the engine, before
  /// `PlayerController` reloads. Elsewhere a 401 recovers through the transport's reactive refresh;
  /// the audio asset is fetched inside AVFoundation, so this is the one path that has to ask.
  /// `false` on every failure (rejected refresh, no renewable session), leaving the item failed
  /// rather than reloading into the same 401; a definitive rejection has already latched the
  /// transport and raised the recovery sheet.
  func renewStreamAuthorizationAndReconfigure() async -> Bool {
    let tracks = await MainActor.run { lastConfiguredTracks }
    guard tracks.isEmpty == false else { return false }
    guard let authorization = try? await underlying.renewStreamAuthorization() else { return false }

    let resources = tracks.map {
      PlaybackTrackResource(
        trackIndex: $0.index,
        url: $0.url,
        headers: authorization.httpHeaderFields(for: $0.url),
        mimeType: $0.mimeType)
    }
    await MainActor.run {
      engine.configure(tracks: resources)
    }
    return true
  }

  func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    await underlying.notifyPlaybackPhase(phase)
  }

  /// Forwarded so a routing child can select the incoming origin before `.buffering` arrives.
  func willStartPlayback(itemID: String) {
    underlying.willStartPlayback(itemID: itemID)
  }

  func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    await underlying.notifyImmediateSyncTrigger(trigger)
  }

  func handleAppBackgrounded() async {
    await underlying.handleAppBackgrounded()
  }

  func recoverOpenSessions() async {
    await underlying.recoverOpenSessions()
  }

  func quiesceForLogout() async {
    await underlying.quiesceForLogout()
  }

  func recordProgressTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
  ) async {
    await underlying.recordProgressTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek, sleepTimerExpired: sleepTimerExpired)
  }
}
