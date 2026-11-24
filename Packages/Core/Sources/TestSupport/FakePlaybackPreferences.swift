import Foundation
import PlayerCore

/// Test double for `PlaybackPreferences`: an in-memory stand-in for whatever real store
/// (UserDefaults, Persistence) a production `PlaybackPreferences` writes to.
public final class FakePlaybackPreferences: PlaybackPreferences, @unchecked Sendable {
  private let storedRate: Locked<Double?>
  private let savedRatesStorage = Locked<[Double]>([])

  public var smartRewindEnabled = true
  public var sleepTimerResumeGraceSeconds: Double = 0

  public var savedRates: [Double] { savedRatesStorage.value }

  public init(initialRate: Double? = nil) {
    storedRate = Locked(initialRate)
  }

  public func loadRate() -> Double? { storedRate.value }

  public func saveRate(_ rate: Double) {
    storedRate.value = rate
    savedRatesStorage.withValue { $0.append(rate) }
  }

  public func loadSmartRewindEnabled() -> Bool { smartRewindEnabled }
  public func loadSleepTimerResumeGraceSeconds() -> Double { sleepTimerResumeGraceSeconds }
}
