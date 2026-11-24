import DesignSystem
import Observation

/// The current, transient skip-feedback episode shared by the expanded-player leaves.
@MainActor @Observable
final class SeekFeedbackState {
  /// The identity a skip episode belongs to. Feedback for one title must never leak into another.
  struct Identity: Equatable {
    let itemID: String
    let episodeID: String?
  }

  /// A scheduler used to keep expiry deterministic in tests.
  typealias ExpiryScheduler =
    @Sendable (
      Duration, @escaping @MainActor () -> Void
    ) -> Task<Void, Never>

  /// The accumulated requested signed delta in seconds, `nil` when no episode is showing.
  private(set) var skipDeltaSeconds: Double?

  private let expire: ExpiryScheduler
  private var identity: Identity?
  private var generation = 0
  /// Outside observation so it stays a stored property: `deinit` (run off the main actor for every
  /// surplus `@State` instance SwiftUI discards) may touch a main-actor class's stored property but
  /// not the computed one `@Observable` synthesises. No isolation opt-out fits:
  /// `nonisolated(unsafe)` only warns it has no effect, and the fix-it's plain `nonisolated`
  /// can't apply to a mutable stored property.
  @ObservationIgnored private var expiryTask: Task<Void, Never>?

  init(expire: @escaping ExpiryScheduler) {
    self.expire = expire
  }

  convenience init() {
    self.init { duration, callback in
      Task { @MainActor in
        do {
          try await Task.sleep(for: duration)
        } catch {
          return
        }
        callback()
      }
    }
  }

  /// Records one requested skip, accumulating only while its identity remains unchanged.
  func recordSkip(delta: Double, identity: Identity) {
    expiryTask?.cancel()
    generation += 1
    let currentGeneration = generation

    if self.identity == identity, let existing = skipDeltaSeconds {
      skipDeltaSeconds = SeekFeedbackPresentation.accumulated(existing: existing, adding: delta)
    } else {
      self.identity = identity
      // Same guard as an accumulating tap, so a non-finite interval cannot open an episode that
      // formats to nothing.
      skipDeltaSeconds = SeekFeedbackPresentation.accumulated(existing: 0, adding: delta)
    }

    expiryTask = expire(PlayerMetric.seekFeedbackSkipWindow) { @MainActor [weak self] in
      guard let self, self.generation == currentGeneration else { return }
      self.cancelSkipEpisode()
    }
  }

  /// Clears the current episode and invalidates every expiry callback already issued for it.
  func cancelSkipEpisode() {
    expiryTask?.cancel()
    expiryTask = nil
    generation += 1
    identity = nil
    skipDeltaSeconds = nil
  }

  deinit {
    expiryTask?.cancel()
  }
}
