import Foundation
import TestSupport
import Testing

@testable import Whirr

/// `UserDefaults` is thread-safe but not annotated `Sendable`; this reader lets the test hand the
/// helper a `Sendable` read closure, as the production default sources do.
nonisolated private struct DefaultsReader: Sendable {
  nonisolated(unsafe) let defaults: UserDefaults

  func value(forKey key: String) -> Int { defaults.integer(forKey: key) }
}

/// `PreferenceChanges` is the one "observe defaults, forward only real changes" helper. Its
/// consumers (`UserDefaultsTrimSilencesPreferences`, `UserDefaultsVoiceBoostDefault`,
/// `AdSkipAnalysisConditions`, `SkipIntervalStore`, `WatchCataloguePublisher`) pin their own use;
/// these cases pin the rule itself.
@Suite("Preference changes", .serialized)
struct PreferenceChangesTests {
  private static let signal = Notification.Name("PreferenceChangesTests.signal")

  private func makeDefaults(_ name: String) throws -> UserDefaults {
    let suite = "PreferenceChangesTests-\(name)-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test("the stream starts with the current value and skips a write that leaves it equal")
  func streamForwardsOnlyRealChanges() async throws {
    let defaults = try makeDefaults("stream")
    defaults.set(1, forKey: "value")
    let reader = DefaultsReader(defaults: defaults)
    let stream = PreferenceChanges.stream(
      read: { reader.value(forKey: "value") },
      notificationNames: [UserDefaults.didChangeNotification],
      object: defaults)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == 1)

    // Every defaults write posts the same notification, whatever the key.
    defaults.set(Date(), forKey: "unrelated")
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    defaults.set(2, forKey: "value")
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(await iterator.next() == 2)
  }

  @Test("an activation re-emit is opt-in")
  func activationReemitIsOptIn() async throws {
    let current = Locked(1)
    let reemitting = PreferenceChanges(
      read: { current.value }, reemitsOnActivation: true, activationName: Self.signal)
    let reemitted = Locked<[Int]>([])
    let reemittingTask = Task {
      var iterator = reemitting.stream(names: [Self.signal]).makeAsyncIterator()
      while let value = await iterator.next() { reemitted.withValue { $0.append(value) } }
    }
    #expect(await waitUntil { reemitted.value == [1] })
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(await waitUntil { reemitted.value == [1, 1] })
    reemittingTask.cancel()

    let quiet = PreferenceChanges(read: { current.value })
    let forwarded = Locked<[Int]>([])
    let quietTask = Task {
      var iterator = quiet.stream(names: [Self.signal]).makeAsyncIterator()
      while let value = await iterator.next() { forwarded.withValue { $0.append(value) } }
    }
    #expect(await waitUntil { forwarded.value == [1] })
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(
      await awaitQuiescence("the unchanged activation stays quiet", stableFor: 50) {
        "\(forwarded.value)"
      }.isObserved)
    #expect(forwarded.value == [1])

    current.value = 2
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(await waitUntil { forwarded.value == [1, 2] })
    #expect(quiet.current == 2)
    quietTask.cancel()
  }

  @Test("cancelling the stream stops every observer")
  func cancellingStopsObservation() async throws {
    let current = Locked(1)
    let changes = PreferenceChanges(read: { current.value })
    let forwarded = Locked<[Int]>([])
    let consumer = Task {
      var iterator = changes.stream(names: [Self.signal]).makeAsyncIterator()
      while let value = await iterator.next() { forwarded.withValue { $0.append(value) } }
    }
    #expect(await waitUntil { forwarded.value == [1] })
    changes.cancel()

    current.value = 2
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(
      await awaitQuiescence("a cancelled stream stays silent", stableFor: 50) {
        "\(forwarded.value)"
      }.isObserved)
    #expect(forwarded.value == [1])
    consumer.cancel()
  }

  @Test("a synchronous observer forwards in place, on the notifying thread")
  func observeForwardsOnlyRealChanges() {
    let current = Locked(1)
    let forwarded = Locked<[Int]>([])
    let changes = PreferenceChanges(read: { current.value })
    changes.observe(names: [Self.signal]) { value in forwarded.withValue { $0.append(value) } }

    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(forwarded.value.isEmpty, "an equal value is not forwarded")

    current.value = 2
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(forwarded.value == [2])
    #expect(changes.current == 2)

    changes.cancel()
    current.value = 3
    NotificationCenter.default.post(name: Self.signal, object: nil)
    #expect(forwarded.value == [2])
  }
}
