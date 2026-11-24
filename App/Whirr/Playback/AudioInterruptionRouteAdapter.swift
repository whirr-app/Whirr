import AVFoundation
import Foundation
import PlayerCore

/// Thin `AVAudioSession` notification adapter (ARCHITECTURE.md §4): maps interruption and
/// route-change payloads to `PlayerCore`'s `PlaybackInterruptionEvent`/`RouteChangeEvent`, runs the
/// pure `PlaybackInterruptionPolicy`/`RouteChangePolicy`, and applies the decision through the
/// same `PlayerIntent.play`/`.pause` as the on-screen and remote controls, so sync-immediate
/// behaviour is identical. AVPlayer's own pause on interruption is not relied on. Owns no session
/// category or activation (`AudioSessionConfigurator`) and no engine.
@MainActor
final class AudioInterruptionRouteAdapter {
  private let player: any PlaybackControlling
  private let notificationCenter: NotificationCenter
  private var interruptionPolicy = PlaybackInterruptionPolicy()
  private var routePolicy = RouteChangePolicy()
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?

  /// `queue: nil` requests synchronous delivery on the posting thread. AVAudioSession's
  /// interruption/route-change notifications are documented to post on the main thread, so
  /// `MainActor.assumeIsolated` below bridges that invariant the same way `PlayerController`
  /// does, keeping this adapter synchronous rather than opening an async gap between a real
  /// interruption and the pause it must produce.
  init(player: any PlaybackControlling, notificationCenter: NotificationCenter = .default) {
    self.player = player
    self.notificationCenter = notificationCenter

    interruptionObserver = notificationCenter.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
    ) { [weak self] notification in
      let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
      guard let self else { return }
      MainActor.assumeIsolated {
        self.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
      }
    }

    routeChangeObserver = notificationCenter.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
    ) { [weak self] notification in
      let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      guard let self else { return }
      MainActor.assumeIsolated {
        self.handleRouteChange(reasonValue: reasonValue)
      }
    }
  }

  /// Call whenever the user explicitly pauses (the same `.pause`/`.toggle` intent on-screen and
  /// remote controls send), including while an interruption is already in progress, so a later
  /// `.ended(shouldResume: true)` never surprise-resumes a book the user paused themselves
  /// (ARCHITECTURE.md §4).
  func userDidPause() {
    interruptionPolicy.userDidPause()
  }

  isolated deinit {
    if let interruptionObserver {
      notificationCenter.removeObserver(interruptionObserver)
    }
    if let routeChangeObserver {
      notificationCenter.removeObserver(routeChangeObserver)
    }
  }

  private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
    guard let typeValue,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    let event: PlaybackInterruptionEvent
    switch type {
    case .began:
      event = .began
    case .ended:
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
      event = .ended(shouldResume: options.contains(.shouldResume))
    @unknown default:
      return
    }

    apply(interruptionPolicy.handle(event, phase: player.state.phase, itemId: player.state.item?.id))
  }

  private func handleRouteChange(reasonValue: UInt?) {
    guard let reasonValue,
      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    let event: RouteChangeEvent
    switch reason {
    case .oldDeviceUnavailable:
      event = .oldDeviceUnavailable
    case .newDeviceAvailable:
      event = .newDeviceAvailable
    case .categoryChange:
      event = .categoryChange
    case .override:
      event = .override
    default:
      event = .other
    }

    apply(routePolicy.handle(event, phase: player.state.phase))
  }

  private func apply(_ action: PlaybackInterruptionPolicy.Action) {
    switch action {
    case .pause: player.send(.pause)
    case .resume: player.send(.play)
    case .none: break
    }
  }

  private func apply(_ action: RouteChangePolicy.Action) {
    switch action {
    case .pause: player.send(.pause)
    case .none: break
    }
  }
}
