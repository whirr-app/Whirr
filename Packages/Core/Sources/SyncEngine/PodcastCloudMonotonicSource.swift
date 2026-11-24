import Foundation

/// Elapsed time for `PodcastCloudClock`, and the process's memory of where its server anchor sits
/// on that timeline.
///
/// An anchored clock advances only by monotonic time elapsed since the anchor was observed. Each
/// production path builds its clock from the installation row inside one transaction, so no clock
/// value lives long enough to carry that observation to the next stamp. This holds it between
/// transactions: `remember` keeps the pairing `observe` made, and `clock(_:)` hands it to a clock
/// rebuilt from a row with the same server anchor.
///
/// The pairing is not persisted (a monotonic reading means nothing to a later process), so after a
/// relaunch the clock holds its physical time until a newer server modification date is observed.
/// A pairing remembered in a transaction that rolls back names an anchor the row never took, so it
/// is never matched.
public final class PodcastCloudMonotonicSource: @unchecked Sendable {
  /// The one production source. Shared rather than injected because the coordinator and the
  /// Saved-shelf resolver are composed separately and stamp from the same installation row.
  public static let process: PodcastCloudMonotonicSource = {
    // `ContinuousClock` keeps counting while the device sleeps; an uptime clock would not.
    let origin = ContinuousClock.now
    return PodcastCloudMonotonicSource(nowMilliseconds: {
      let elapsed = (ContinuousClock.now - origin).components
      return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    })
  }()

  private struct Pairing {
    let serverMilliseconds: Int64
    let monotonicMilliseconds: Int64
  }

  private let reading: @Sendable () -> Int64
  private let lock = NSLock()
  private var pairings: [UUID: Pairing] = [:]

  /// `nowMilliseconds` must never decrease and must keep counting through device sleep.
  public init(nowMilliseconds: @escaping @Sendable () -> Int64) {
    self.reading = nowMilliseconds
  }

  /// Read inside the transaction that stamps, never before queueing for it: the write queue
  /// orders transactions, and a reading taken earlier could predate an anchor set by a
  /// transaction that ran first.
  func nowMilliseconds() -> Int64 { max(0, reading()) }

  func clock(_ state: PodcastCloudClockState) -> PodcastCloudClock {
    lock.lock()
    defer { lock.unlock() }
    guard let pairing = pairings[state.installationUUID],
      pairing.serverMilliseconds == state.anchorServerMilliseconds
    else { return PodcastCloudClock(state: state) }
    return PodcastCloudClock(state: state, monotonicAnchor: pairing.monotonicMilliseconds)
  }

  func remember(_ clock: PodcastCloudClock) {
    guard let server = clock.state.anchorServerMilliseconds, let monotonic = clock.monotonicAnchor
    else { return }
    lock.lock()
    defer { lock.unlock() }
    pairings[clock.state.installationUUID] = Pairing(
      serverMilliseconds: server, monotonicMilliseconds: monotonic)
  }
}
