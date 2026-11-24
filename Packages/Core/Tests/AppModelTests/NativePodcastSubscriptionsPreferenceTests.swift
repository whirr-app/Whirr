import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite struct NativePodcastSubscriptionsPreferenceTests {
  @Test func absentValueDefaultsOnAndImmediatelyObserves() async {
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    let preference = NativePodcastSubscriptionsPreference(defaults: defaults)
    var iterator = preference.observeEnabled().makeAsyncIterator()

    #expect(await preference.isEnabled())
    #expect(await iterator.next() == true)
  }

  @Test func writesPersistAndBroadcastOnlyChanges() async {
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    let preference = NativePodcastSubscriptionsPreference(defaults: defaults)
    var iterator = preference.observeEnabled().makeAsyncIterator()
    _ = await iterator.next()

    await preference.setEnabled(false)

    #expect(await iterator.next() == false)
    #expect(defaults.boolValue(forKey: NativePodcastSubscriptionsPreference.storageKey) == false)
    #expect(await preference.isEnabled() == false)
  }

  @Test func storedValueSurvivesReconstruction() async {
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    let first = NativePodcastSubscriptionsPreference(defaults: defaults)
    await first.setEnabled(false)

    let restored = NativePodcastSubscriptionsPreference(defaults: defaults)

    #expect(await restored.isEnabled() == false)
  }

  @Test func disablingNativeSubscriptionsDisarmsNotificationsBeforeWritingThePreference() async {
    let events = NativeToggleEvents()
    let preference = RecordingNativePreference(events: events)
    let lifecycle = RecordingToggleNotificationLifecycle(events: events)
    let subject = NotificationDisarmingNativePodcastSubscriptions(
      writing: preference, notifications: lifecycle)

    await subject.setEnabled(false)

    #expect(await events.values == [.disarmAll, .write(false)])
  }
}

private actor NativeToggleEvents {
  enum Event: Equatable {
    case disarmAll
    case write(Bool)
  }

  private(set) var values: [Event] = []
  func append(_ event: Event) { values.append(event) }
}

private struct RecordingNativePreference: NativePodcastSubscriptionsWriting {
  let events: NativeToggleEvents
  func setEnabled(_ enabled: Bool) async { await events.append(.write(enabled)) }
}

// Kept: it appends to the same ordered log as `RecordingNativePreference`, to prove that
// disarming comes before the write.
private struct RecordingToggleNotificationLifecycle: RSSNotificationLifecycleHandling {
  let events: NativeToggleEvents
  func disarm(feedID: Int64?) async {
    if feedID == nil { await events.append(.disarmAll) }
  }
}
