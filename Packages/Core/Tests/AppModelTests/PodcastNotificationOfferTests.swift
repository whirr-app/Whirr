import AppModel
import SyncEngine
import TestSupport
import Testing

@Suite("Podcast notification offer")
struct PodcastNotificationOfferTests {
  private typealias Inputs = PodcastNotificationOfferPresentation.Inputs

  private static let presentable = Inputs(
    hasLoaded: true, nativeSubscriptionsEnabled: true, hasFollowedShows: true,
    filterShowsOffer: true, hasPlaceholder: false, isEnabled: false,
    authorizationStatus: .notDetermined, isAnswered: false)

  private func presents(_ change: (inout Inputs) -> Void) -> Bool {
    var inputs = Self.presentable
    change(&inputs)
    return PodcastNotificationOfferPresentation.shouldPresent(inputs)
  }

  @Test("the offer presents to a follower with notifications off and undecided")
  func presentsWhenActionable() {
    #expect(presents { _ in })
  }

  @Test("an unloaded model never presents, because it reads as off for everyone")
  func unloadedDoesNotPresent() {
    #expect(presents { $0.hasLoaded = false } == false)
  }

  @Test("nothing to notify about means no offer")
  func needsFollowedNativeShows() {
    #expect(presents { $0.nativeSubscriptionsEnabled = false } == false)
    #expect(presents { $0.hasFollowedShows = false } == false)
  }

  @Test("the offer stays out of the Downloaded filter and from under a placeholder")
  func staysClearOfPlaceholders() {
    #expect(presents { $0.filterShowsOffer = false } == false)
    #expect(presents { $0.hasPlaceholder = true } == false)
  }

  @Test("notifications already on need no offer")
  func enabledDoesNotPresent() {
    #expect(presents { $0.isEnabled = true } == false)
  }

  @Test("a granted authorization still presents; a denied one cannot be fixed from the card")
  func authorization() {
    #expect(presents { $0.authorizationStatus = .allowed })
    #expect(presents { $0.authorizationStatus = .denied } == false)
  }

  @Test("Background App Refresh that is off or restricted cannot be fixed from the card")
  func backgroundRefresh() {
    #expect(presents { $0.backgroundRefreshStatus = .available })
    #expect(presents { $0.backgroundRefreshStatus = .pausedByLowPowerMode })
    #expect(presents { $0.backgroundRefreshStatus = .denied } == false)
    #expect(presents { $0.backgroundRefreshStatus = .restricted } == false)
  }

  @Test("an answered offer never returns")
  func answeredDoesNotPresent() {
    #expect(presents { $0.isAnswered = true } == false)
  }

  @Test("the marker starts unanswered, persists, and is read back by a new instance")
  func markerRoundTrip() {
    let defaults = FakeNativePodcastSubscriptionsDefaults()
    let marker = PodcastNotificationOfferPreference(defaults: defaults)
    #expect(marker.isAnswered() == false)
    marker.markAnswered()
    #expect(defaults.values[PodcastNotificationOfferPreference.storageKey] == true)
    #expect(PodcastNotificationOfferPreference(defaults: defaults).isAnswered())
  }

  @Test("the marker has its own key")
  func markerKeyIsDistinct() {
    #expect(
      PodcastNotificationOfferPreference.storageKey != PodcastNotificationPreference.storageKey)
  }
}
