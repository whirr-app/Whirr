import AdSkip
import AppModel
import Foundation

/// What a Look Back sheet runs on: the recogniser gate shared with ad skip and podcast
/// transcripts, and its own ungated transcriber (the run holds the gate).
/// The text it makes stays in memory (SECURITY.md rule 20).
@MainActor
enum LookBackComposition {
  static func dependencies() -> LookBackModel.Dependencies {
    let transcripts = TranscriptComposition.coordinator
    let installer = SpeechAssetInstaller()
    return LookBackModel.Dependencies(
      coordinator: LookBackCoordinator(
        dependencies: .init(
          gate: TranscriptComposition.gate, transcriber: SpeechEpisodeTranscriber(),
          yieldTranscripts: { await transcripts?.yieldForLookBack() },
          resumeTranscripts: { await transcripts?.resumeAfterLookBack() },
          isTooHot: { ProcessInfo.processInfo.thermalState == .critical })),
      assetState: { assetState(await installer.state()) },
      installAsset: { try await installer.install() })
  }

  /// A download already under way is offered again: installing joins it.
  nonisolated static func assetState(_ state: SpeechAssetState) -> LookBackModel.AssetState {
    switch state {
    case .unavailable: .unsupported
    case .notInstalled, .downloading: .downloadable
    case .installed: .installed
    }
  }
}
