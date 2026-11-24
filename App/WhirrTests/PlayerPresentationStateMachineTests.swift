import AppModel
import Persistence
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

@Suite("Player presentation state machine")
struct PlayerPresentationStateMachineTests {

  /// The host receives app appearance before creation so system controls and status bar match.
  @MainActor
  @Test("the player host starts system presentations in the requested app appearance")
  func playerHostOwnsThePagesAppearance() {
    let dark = PlayerHostingController(rootView: EmptyView(), chromeColorScheme: .dark)

    #expect(dark.overrideUserInterfaceStyle == .dark)
    #expect(dark.preferredStatusBarStyle == .lightContent)
    #expect(dark.modalPresentationCapturesStatusBarAppearance)

    let light = PlayerHostingController(rootView: EmptyView(), chromeColorScheme: .light)

    #expect(light.overrideUserInterfaceStyle == .light)
    #expect(light.preferredStatusBarStyle == .darkContent)
    #expect(light.modalPresentationCapturesStatusBarAppearance)
  }

  /// A user appearance change also updates a player that is already presented.
  @MainActor
  @Test("the player host accepts an explicit appearance change")
  func playerHostFollowsALaterPolarity() {
    let host = PlayerHostingController(rootView: EmptyView(), chromeColorScheme: .dark)

    host.chromeColorScheme = .light

    #expect(host.overrideUserInterfaceStyle == .light)
    #expect(host.preferredStatusBarStyle == .darkContent)
  }

  /// The page has no text input of its own. Its search field lives in the chapters sheet, a
  /// separate presentation, so keyboard avoidance on this host can only do harm: a keyboard-hide
  /// notification computed mid-transition could leave the inset stuck, condensing the page into
  /// the top half of the screen until relaunch.
  @MainActor
  @Test("the player host ignores the keyboard safe-area region")
  func playerHostIgnoresKeyboardRegion() {
    let host = PlayerHostingController(rootView: EmptyView(), chromeColorScheme: .dark)

    #expect(host.safeAreaRegions == .container)
  }

  @Test("a requested presentation presents only from idle")
  func requestedPresentationActions() {
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .idle, isPresentedRequested: true) == .present)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .presenting, isPresentedRequested: true) == .updateContent)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .presented, isPresentedRequested: true) == .updateContent)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .interacting, isPresentedRequested: true) == .updateContent)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .dismissing, isPresentedRequested: true) == .ignore)
  }

  @Test("a second present request updates content without presenting again")
  func secondPresentRequestUpdatesContent() {
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .presented, isPresentedRequested: true) == .updateContent)
  }

  @Test("a requested dismissal dismisses only from presented")
  func requestedDismissalActions() {
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .idle, isPresentedRequested: false) == .ignore)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .presenting, isPresentedRequested: false) == .ignore)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .presented, isPresentedRequested: false) == .dismiss)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .interacting, isPresentedRequested: false) == .ignore)
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .dismissing, isPresentedRequested: false) == .ignore)
  }

  @Test("a second dismissal request while interacting is ignored")
  func dismissalWhileInteractingIsIgnored() {
    #expect(
      PlayerPresentationStateMachine.action(
        phase: .interacting, isPresentedRequested: false) == .ignore)
  }

  @Test("interactive dismissal begins only from presented")
  func interactiveBeginRequiresPresentedPhase() {
    #expect(
      PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: .idle) == nil)
    #expect(
      PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: .presenting) == nil)
    #expect(
      PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: .presented)
        == .interacting)
    #expect(
      PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: .interacting) == nil)
    #expect(
      PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: .dismissing) == nil)
  }

  @Test("completed and cancelled dismissals return to their serialized phases")
  func dismissalEndPhases() {
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .idle, completed: true) == .idle)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .presenting, completed: true) == .idle)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .presented, completed: true) == .idle)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .interacting, completed: true) == .idle)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .dismissing, completed: true) == .idle)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .idle, completed: false) == .presented)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .presenting, completed: false) == .presented)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .presented, completed: false) == .presented)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .interacting, completed: false) == .presented)
    #expect(
      PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: .dismissing, completed: false) == .presented)
  }

  @Test("cancellation returns to presented without completion cleanup")
  func cancellationRunsNoCleanup() {
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .idle, completed: false) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .presenting, completed: false) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .presented, completed: false) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .interacting, completed: false) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .dismissing, completed: false) == false)
  }

  @Test("cleanup includes a completed dismissal initiated by UIKit while presented")
  func completionCleanupRequiresCompletedDismissal() {
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .idle, completed: true) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .presenting, completed: true) == false)
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .presented, completed: true))
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .interacting, completed: true))
    #expect(
      PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: .dismissing, completed: true))
  }

  // MARK: - Collapse motion

  /// A slide translates by the container height. A dissolve fades and settles to
  /// `dissolveEndScale`, and keeps only the fade under Reduce Motion.
  @Test("a slide translates by the container height whatever the motion setting")
  func slideTranslatesByContainerHeight() {
    #expect(
      PlayerCollapseMotion.resolve(style: .slide, containerHeight: 812, reduceMotion: false)
        == .slide(translationY: 812))
    #expect(
      PlayerCollapseMotion.resolve(style: .slide, containerHeight: 812, reduceMotion: true)
        == .slide(translationY: 812))
  }

  @Test("a dissolve fades and settles, and drops the settle under Reduce Motion")
  func dissolveFadesAndSettles() {
    #expect(
      PlayerCollapseMotion.resolve(style: .dissolve, containerHeight: 812, reduceMotion: false)
        == .dissolve(alpha: 0, scale: ExpandedPlayerHostPresentation.dissolveEndScale))
    #expect(
      PlayerCollapseMotion.resolve(style: .dissolve, containerHeight: 812, reduceMotion: true)
        == .dissolve(alpha: 0, scale: 1))
    #expect(ExpandedPlayerHostPresentation.dissolveEndScale < 1)
    #expect(ExpandedPlayerHostPresentation.dissolveEndScale > 0.9)
  }

  @Test("collapse durations follow the plan's table")
  func collapseDurationsFollowTheTable() {
    #expect(
      PlayerCollapseMotion.duration(style: .slide, reduceMotion: false)
        == ExpandedPlayerHostPresentation.slideDuration)
    #expect(
      PlayerCollapseMotion.duration(style: .dissolve, reduceMotion: false)
        == ExpandedPlayerHostPresentation.dissolveDuration)
    #expect(ExpandedPlayerHostPresentation.dissolveDuration < 0.34)
    #expect(PlayerCollapseMotion.duration(style: .slide, reduceMotion: true) == 0.2)
    #expect(PlayerCollapseMotion.duration(style: .dissolve, reduceMotion: true) == 0.2)
  }

  /// The animator defaults to a slide, so the presentation path and the interactive dismissal,
  /// which never set a style, keep the slide motion.
  @MainActor
  @Test("the animator defaults to a slide and carries a requested dissolve")
  func animatorCarriesItsStyle() {
    #expect(PlayerTransitionAnimator(direction: .dismiss).style == .slide)
    #expect(PlayerTransitionAnimator(direction: .present).style == .slide)
    #expect(PlayerTransitionAnimator(direction: .dismiss, style: .dissolve).style == .dissolve)

    let delegate = PlayerTransitioningDelegate()
    #expect(delegate.dismissStyle == .slide)
    delegate.dismissStyle = .dissolve
    let dismissed = UIViewController()
    let animator = delegate.animationController(forDismissed: dismissed) as? PlayerTransitionAnimator
    #expect(animator?.style == .dissolve)
  }
}

/// The expanded player is a UIKit-presented hosting controller, so it sits outside the SwiftUI
/// scene that supplies `scenePhase`. Left alone, the page reads `.background` for as long as it is
/// on screen, and every gate built on that, including the audio-route refresh, stays shut. The
/// presentation must carry the presenting scene's phase across that boundary.
@MainActor
@Suite("Player presentation scene phase", .timeLimit(.minutes(1)))
struct PlayerPresentationScenePhaseTests {

  @Test("presented player content reads the presenting scene's phase and follows it")
  func presentedContentFollowsThePresentingScenePhase() async {
    await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: 393, height: 852)) { scope in
      let recorder = ScenePhaseRecorder()
      let host = scope.host(PresentingScene(phase: .active, recorder: recorder))
      defer { host.presentedViewController?.dismiss(animated: false) }

      _ = await awaitCondition(
        "presented page reports a phase", observing: { "\(recorder.phases)" },
        until: { recorder.latest != nil })
      #expect(recorder.latest == .active)

      host.rootView = PresentingScene(phase: .background, recorder: recorder)
      let followed = await awaitCondition(
        "presented page follows the scene to background", recordingIssue: false,
        observing: { "\(recorder.phases)" }, until: { recorder.latest == .background })
      #expect(followed.isObserved)
      #expect(recorder.latest == .background)
    }
  }
}

/// The same boundary drops custom environment values. The speed card's per-show Voice Boost and
/// Trim Silences rows read `showPlaybackEffects`, which the shell publishes. Without it the card
/// falls back to the app-wide Voice Boost row and shows no Trim Silences.
@MainActor
@Suite("Player presentation show playback effects", .timeLimit(.minutes(1)))
struct PlayerPresentationShowPlaybackEffectsTests {

  @Test("presented player content reads the presenting shell's show playback effects")
  func presentedContentReadsTheShowPlaybackEffects() async throws {
    let database = try AppDatabase.inMemory()
    let harness = UIHarnessSession()
    let access = ShowPlaybackEffectsAccess(
      trimSettings: RoutingTrimSilencesShowSettingsAccess(
        abs: PodcastSettingsStore(database: database, accountId: 1),
        rss: RSSFeedSettingsStore(database: database)),
      trimDefaults: UserDefaultsTrimSilencesPreferences(),
      voiceBoostSettings: RoutingVoiceBoostShowSettingsAccess(
        abs: PodcastSettingsStore(database: database, accountId: 1),
        rss: RSSFeedSettingsStore(database: database)),
      voiceBoostDefault: UserDefaultsVoiceBoostDefault(),
      playback: harness.playback)

    await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: 393, height: 852)) { scope in
      let recorder = EffectsAccessRecorder()
      let host = scope.host(
        Color.clear
          .interactivePlayerPresentation(
            isPresented: .constant(true), chromeColorScheme: .dark, onDismissCompleted: {}
          ) {
            EffectsAccessProbe(recorder: recorder)
          }
          .environment(\.showPlaybackEffects, access))
      defer { host.presentedViewController?.dismiss(animated: false) }

      _ = await awaitCondition(
        "presented page reports its access", observing: { "\(recorder.readings)" },
        until: { recorder.readings.isEmpty == false })
      #expect(recorder.readings.last == true)
    }
  }
}

@MainActor
private final class EffectsAccessRecorder {
  private(set) var readings: [Bool] = []

  func record(_ isPresent: Bool) {
    readings.append(isPresent)
  }
}

private struct EffectsAccessProbe: View {
  let recorder: EffectsAccessRecorder
  @Environment(\.showPlaybackEffects) private var showPlaybackEffects

  var body: some View {
    Color.clear
      .onChange(of: showPlaybackEffects != nil, initial: true) { _, isPresent in
        recorder.record(isPresent)
      }
  }
}

@MainActor
private final class ScenePhaseRecorder {
  private(set) var phases: [ScenePhase] = []

  var latest: ScenePhase? { phases.last }

  func record(_ phase: ScenePhase) {
    phases.append(phase)
  }
}

/// Stands in for the shell: a view inside a scene, presenting the player over itself.
private struct PresentingScene: View {
  let phase: ScenePhase
  let recorder: ScenePhaseRecorder

  var body: some View {
    Color.clear
      .interactivePlayerPresentation(
        isPresented: .constant(true), chromeColorScheme: .dark, onDismissCompleted: {}
      ) {
        ScenePhaseProbe(recorder: recorder)
      }
      // The test window is itself UIKit-hosted, so the phase a real scene would supply is set here.
      .environment(\.scenePhase, phase)
  }
}

private struct ScenePhaseProbe: View {
  let recorder: ScenePhaseRecorder
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Color.clear
      .onChange(of: scenePhase, initial: true) { _, phase in
        recorder.record(phase)
      }
  }
}
