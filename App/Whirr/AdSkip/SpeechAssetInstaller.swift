import Foundation
import Speech

nonisolated enum SpeechAssetState: Sendable, Equatable {
  /// No recogniser for the pinned locale on this device or OS; the setting is never shown.
  case unavailable
  case notInstalled
  case downloading
  case installed
}

/// Checks and installs the English transcription asset. Installing uses the network,
/// so callers ask the listener first.
nonisolated struct SpeechAssetInstaller: Sendable {

  func state() async -> SpeechAssetState {
    guard SpeechTranscriber.isAvailable, let locale = await AdSkipSpeech.locale() else {
      return .unavailable
    }
    return Self.state(
      for: await AssetInventory.status(forModules: [AdSkipSpeech.transcriber(for: locale)]))
  }

  /// Downloads and installs the asset if it is missing. `progress` receives the system's progress
  /// object before the download starts; it is not called when nothing needs installing.
  func install(progress: @Sendable (Progress) -> Void = { _ in }) async throws {
    guard SpeechTranscriber.isAvailable else { throw SpeechEpisodeTranscriber.Failure.unavailable }
    guard let locale = await AdSkipSpeech.locale() else {
      throw SpeechEpisodeTranscriber.Failure.unsupportedLocale
    }
    guard
      let request = try await AssetInventory.assetInstallationRequest(
        supporting: [AdSkipSpeech.transcriber(for: locale)])
    else { return }
    progress(request.progress)
    try await request.downloadAndInstall()
  }

  static func state(for status: AssetInventory.Status) -> SpeechAssetState {
    switch status {
    case .unsupported: .unavailable
    case .supported: .notInstalled
    case .downloading: .downloading
    case .installed: .installed
    @unknown default: .unavailable
    }
  }
}
