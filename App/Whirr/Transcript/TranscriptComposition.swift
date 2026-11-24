import AdSkip
import AppModel
import CoreSupport
import Foundation
import Persistence
import UIKit
import os

/// The process-lifetime transcript coordinator and the recogniser gate it shares with ad skip.
/// Device-owned like ad skip, and composed apart from `AdSkipComposition.makeCoordinator`, which
/// returns nil when ad skip cannot start, so transcripts work with ad skip off or unavailable.
@MainActor
enum TranscriptComposition {
  /// One analyser at a time: ad skip's transcriber is reached only through it.
  static let gate = TranscriberGate()

  /// The second transcript root, beside ad skip's (SECURITY.md rule 20). Each root's sweep deletes
  /// the files its own table does not name, so the two never share one.
  static let directoryName = "Transcripts"

  /// Built on first use; nil while the database cannot open (a background launch before the first
  /// unlock), and a later call builds it.
  static var coordinator: EpisodeTranscriptCoordinator? {
    if isBuilt == false {
      guard let database = DatabaseHardware.sharedIfAvailable() else { return nil }
      isBuilt = true
      instance = makeCoordinator(database: database)
    }
    return instance
  }

  private static var isBuilt = false
  private static var instance: EpisodeTranscriptCoordinator?
  private static var isStarted = false

  private static let log = CoreLogging.logger(category: "Transcript")

  static func runForLaunch() async {
    guard isStarted == false, let coordinator, let database = DatabaseHardware.sharedIfAvailable()
    else { return }
    isStarted = true
    await coordinator.start(
      localEpisodes: AdSkipComposition.makeLocalEpisodeReader(database: database)
        .observeLocalEpisodes(),
      isAllowed: AdSkipAnalysisConditions.changesIgnoringCharging(),
      isForeground: foregroundChanges(),
      isPlaying: playingChanges())
  }

  private static func makeCoordinator(database: AppDatabase) -> EpisodeTranscriptCoordinator? {
    let files: AdSkipTranscriptFileStore
    do {
      files = try AdSkipTranscriptFileStore(
        rootURL: DatabaseHardware.applicationSupportDirectory()
          .appendingPathComponent(directoryName, isDirectory: true),
        fileAttributes: POSIXFileAttributeApplier())
    } catch {
      // Transcripts stay unavailable for this launch. Only the error's type is logged, never a path.
      log.error("Transcripts unavailable: \(String(describing: type(of: error)), privacy: .public)")
      return nil
    }
    return EpisodeTranscriptCoordinator(
      dependencies: .init(
        store: EpisodeTranscriptStore(database: database, files: files),
        session: SpeechTranscriptSession(), gate: gate,
        transcriberRevision: SpeechEpisodeTranscriber.revision))
  }

  /// Whether a scene is in the foreground: now, then on every move in or out.
  private static func foregroundChanges() -> AsyncStream<Bool> {
    AsyncStream { continuation in
      continuation.yield(UIApplication.shared.applicationState != .background)
      let center = NotificationCenter.default
      let observers = [
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in continuation.yield(true) },
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in continuation.yield(false) },
      ]
      continuation.onTermination = { _ in
        for observer in observers { center.removeObserver(observer) }
      }
    }
  }

  /// Whether the player means to be playing: audio keeps the process alive in the background.
  private static func playingChanges() -> AsyncStream<Bool> {
    let player = PlaybackHardware.shared.player
    let intents = Observations { player.isPlaybackIntended }
    return AsyncStream { continuation in
      let task = Task { @MainActor in
        for await playing in intents { continuation.yield(playing) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
