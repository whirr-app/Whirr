import AVFoundation
import PlayerCore
import Testing

@testable import Whirr

/// Covers `AudioInterruptionRouteAdapter`, fed real `AVAudioSession` interruption and route-change
/// payloads posted on a private `NotificationCenter`, never the process-wide `.default`. It maps
/// them to `PlayerCore`'s plain events and carries them out through the same `PlayerIntent.play`
/// and `.pause` that on-screen and remote controls use. It also covers observer teardown once the
/// adapter is deallocated.
@MainActor
@Suite("AudioInterruptionRouteAdapter")
struct AudioInterruptionRouteAdapterTests {

  private static func playingState(itemId: String = "item-1") -> PlayerState {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    let item = PlayerItem(id: itemId, timeline: timeline)
    return PlayerState(phase: .playing, item: item, currentTrackIndex: 0, globalPosition: 10, rate: 1.0)
  }

  private static func pausedState(itemId: String = "item-1") -> PlayerState {
    var state = playingState(itemId: itemId)
    state.phase = .paused
    return state
  }

  private func interruptionNotification(
    center: NotificationCenter, type: AVAudioSession.InterruptionType, shouldResume: Bool = false
  ) {
    var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
    if type == .ended {
      let options: AVAudioSession.InterruptionOptions = shouldResume ? .shouldResume : []
      userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
    }
    center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
  }

  private func routeChangeNotification(center: NotificationCenter, reason: AVAudioSession.RouteChangeReason) {
    center.post(
      name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
  }

  // MARK: - Interruption payload mapping

  @Test("interruption began while playing maps to .began and sends .pause")
  func interruptionBeganWhilePlayingPauses() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    interruptionNotification(center: center, type: .began)

    #expect(player.sentIntents == [.pause])
    withExtendedLifetime(adapter) {}
  }

  @Test(
    "interruption ended with shouldResume after an active interruption maps to .ended(shouldResume: true) and sends .play"
  )
  func interruptionEndedWithShouldResumeResumes() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    interruptionNotification(center: center, type: .began)
    player.state = Self.pausedState()
    interruptionNotification(center: center, type: .ended, shouldResume: true)

    #expect(player.sentIntents == [.pause, .play])
    withExtendedLifetime(adapter) {}
  }

  @Test("interruption ended without shouldResume sends no further intent")
  func interruptionEndedWithoutShouldResumeTakesNoAction() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    interruptionNotification(center: center, type: .began)
    player.state = Self.pausedState()
    interruptionNotification(center: center, type: .ended, shouldResume: false)

    #expect(player.sentIntents == [.pause])
    withExtendedLifetime(adapter) {}
  }

  @Test("a user pause recorded during an interruption prevents the eventual shouldResume from resuming")
  func userPauseDuringInterruptionPreventsResume() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    interruptionNotification(center: center, type: .began)
    player.state = Self.pausedState()
    adapter.userDidPause()
    interruptionNotification(center: center, type: .ended, shouldResume: true)

    #expect(player.sentIntents == [.pause])
  }

  @Test("a malformed interruption payload is ignored")
  func malformedInterruptionPayloadIsIgnored() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: nil)

    #expect(player.sentIntents.isEmpty)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Route-change payload mapping

  @Test("old-device-unavailable route change while playing maps to .oldDeviceUnavailable and sends .pause")
  func oldDeviceUnavailableWhilePlayingPauses() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    routeChangeNotification(center: center, reason: .oldDeviceUnavailable)

    #expect(player.sentIntents == [.pause])
    withExtendedLifetime(adapter) {}
  }

  @Test("new device, category-change, and override route reasons take no action")
  func benignRouteChangeReasonsTakeNoAction() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    routeChangeNotification(center: center, reason: .newDeviceAvailable)
    routeChangeNotification(center: center, reason: .categoryChange)
    routeChangeNotification(center: center, reason: .override)

    #expect(player.sentIntents.isEmpty)
    withExtendedLifetime(adapter) {}
  }

  @Test("route changes never send .play - no automatic resume")
  func routeChangesNeverSendPlay() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    let adapter = AudioInterruptionRouteAdapter(player: player, notificationCenter: center)

    routeChangeNotification(center: center, reason: .oldDeviceUnavailable)
    player.state = Self.pausedState()
    routeChangeNotification(center: center, reason: .oldDeviceUnavailable)

    #expect(player.sentIntents == [.pause])
    #expect(!player.sentIntents.contains(.play))
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Observer teardown

  @Test("deallocating the adapter removes its observers - a later notification reaches no one")
  func deallocationRemovesObservers() {
    let center = NotificationCenter()
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.playingState()
    var adapter: AudioInterruptionRouteAdapter? = AudioInterruptionRouteAdapter(
      player: player, notificationCenter: center)
    #expect(adapter != nil)
    adapter = nil

    interruptionNotification(center: center, type: .began)
    routeChangeNotification(center: center, reason: .oldDeviceUnavailable)

    #expect(player.sentIntents.isEmpty)
  }
}
