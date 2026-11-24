import Persistence

/// The three durable writes `PlaybackSessionCoordinator.persistTick` can make, as a protocol so a
/// test can make one throw (a mid-listen SQLite failure is disk-full or corruption no fixture can
/// provoke; a throwing `recordLocalTick` must not count as handled). `PlaybackSessionStore`
/// already has these signatures, so the conformance is empty.
protocol PlaybackTickWriting: Sendable {
  func recordNextTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord
  func recordLocalTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord
  func recordSessionlessTick(
    accountId: Int64, itemId: Int64, podcastEpisodeId: Int64?, serverItemId: String, tick: PlaybackTick
  ) throws -> MediaProgressRecord
}

extension PlaybackSessionStore: PlaybackTickWriting {}
