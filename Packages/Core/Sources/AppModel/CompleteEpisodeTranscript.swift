import AdSkip
import Foundation
import Persistence

/// A listener transcript that covers its whole episode, for the file as it is now.
///
/// A transcript is user content: never log it, its file name or its words.
public struct CompleteEpisodeTranscript: Sendable, Equatable {
  /// Names the stored file, which changes whenever the words do, so it keys anything derived
  /// from them.
  public let fileName: String
  public let transcript: Transcript

  public init(fileName: String, transcript: Transcript) {
    self.fileName = fileName
    self.transcript = transcript
  }
}

/// What ad skip may read of the listener's transcripts: only complete ones, and when that answer
/// may have changed. `EpisodeTranscriptCoordinator` is the one production reader.
public protocol CompleteEpisodeTranscriptReading: Sendable {
  /// Nil unless the episode's stored transcript is complete and was made from the file as it is
  /// now. A running session's partial words never come back.
  func completeTranscript(for identity: AdSkipEpisodeIdentity) async -> CompleteEpisodeTranscript?

  /// Each episode whose answer from `completeTranscript(for:)` may have changed since the stream
  /// was made: a transcript completed, or a complete one was removed. Nothing is replayed.
  func completeTranscriptChanges() async -> AsyncStream<AdSkipEpisodeIdentity>
}
