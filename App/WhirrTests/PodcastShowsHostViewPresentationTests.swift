import AppModel
import Persistence
import Testing

@testable import Whirr

@Suite("Podcast shows host presentation")
struct PodcastShowsHostViewPresentationTests {
  @Test("route identity selects the corresponding source")
  func routeSelectsSource() {
    #expect(
      PodcastShowsHostViewPresentation.initialSource(for: .podcastShows)
        == .server)
    #expect(
      PodcastShowsHostViewPresentation.initialSource(for: .nativePodcastShows)
        == .followed)
  }

  @Test("a disabled native source falls back to server for a retained server route")
  func disabledNativeSourceFallsBackToServer() {
    #expect(
      PodcastShowsHostViewPresentation.source(
        for: .podcastShows, nativeSubscriptionsEnabled: false)
        == .server)
    #expect(
      PodcastShowsHostViewPresentation.source(
        for: .nativePodcastShows, nativeSubscriptionsEnabled: false)
        == .server)
  }

  @Test("picker labels and source route tokens stay distinct")
  func pickerCopyAndRouteTokens() {
    #expect(
      PodcastShowsHostViewPresentation.Source.allCases.map(\.label)
        == ["Followed", "On your server"])
  }

  @MainActor
  @Test("both historical destinations keep their restoration token and host composition")
  func routeTokensRoundTripThroughTheCombinedHost() {
    let server = NavigationModel.Destination(
      section: .podcasts, path: [.podcastShows])
    let followed = NavigationModel.Destination(
      section: .podcasts, path: [.nativePodcastShows])

    #expect(server.deepLinkPath == "podcasts/podcast-shows")
    #expect(followed.deepLinkPath == "podcasts/your-shows")
    #expect(NavigationModel.Destination(deepLinkPath: server.deepLinkPath) == server)
    #expect(NavigationModel.Destination(deepLinkPath: followed.deepLinkPath) == followed)
  }

  @Test("the source picker exposes availability without changing route identity")
  func sourceAvailabilityIsIndependentFromRouteIdentity() {
    #expect(
      PodcastShowsHostViewPresentation.sourceIsAvailable(
        .server, nativeSubscriptionsEnabled: false))
    #expect(
      PodcastShowsHostViewPresentation.sourceIsAvailable(
        .followed, nativeSubscriptionsEnabled: false) == false)
    #expect(PodcastShowsHostViewPresentation.isNativeOriginating(.nativePodcastShows))
    #expect(PodcastShowsHostViewPresentation.isNativeOriginating(.podcastShows) == false)
  }

  @Test("the root heading chooses a historical route token from live source availability")
  func headingRoutePreservesBothTokens() {
    #expect(
      PodcastShowsHostViewPresentation.headingRoute(
        nativeSubscriptionsEnabled: true, hasFollowedShows: true) == .nativePodcastShows)
    #expect(
      PodcastShowsHostViewPresentation.headingRoute(
        nativeSubscriptionsEnabled: true, hasFollowedShows: false) == .podcastShows)
    #expect(
      PodcastShowsHostViewPresentation.headingRoute(
        nativeSubscriptionsEnabled: false, hasFollowedShows: true) == .podcastShows)
    #expect(
      PodcastShowsHostViewPresentation.headingRoute(
        nativeSubscriptionsEnabled: false, hasFollowedShows: false) == .podcastShows)
  }

  @Test("source switching is blocked while a child has a confirmation")
  @MainActor
  func sourceSwitchGateBlocksConfirmation() {
    let gate = PodcastShowsSourceSwitchGate()
    var confirmationPresented = true
    gate.register(source: .followed) { !confirmationPresented }

    #expect(gate.prepare(source: .followed) == false)
    confirmationPresented = false
    #expect(gate.prepare(source: .followed))
  }
}
