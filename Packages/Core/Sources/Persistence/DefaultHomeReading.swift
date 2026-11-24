import Foundation
import GRDB

/// The production `HomeReading` conformance: a GRDB `ValueObservation` bridged to an `AsyncStream`
/// per method, so no GRDB type crosses into AppModel (ARCHITECTURE.md §1). Mirrors
/// `DefaultLibraryReading`/`DefaultDownloadReading`. The single account row (`AccountDAO`'s
/// contract) is resolved inside the tracked closure, so a stream started before login emits once
/// it appears.
public struct DefaultHomeReading: HomeReading, Sendable {
  /// Product policy: under a minute of trailing audio (credits, adverts, silence) counts as
  /// complete. Presentation only (no durable completion or position change); both podcast shelves
  /// apply it so an episode is never hidden from one and kept in the other.
  static let minimumRemainingSeconds = LatestPodcastEpisodePolicy.minimumRemainingSeconds

  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }
}
