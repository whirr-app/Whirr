import AppModel
import SwiftUI

#if PERF_INVESTIGATION
  import QuartzCore
#endif

extension SceneRegistry.Effects {
  /// Which scenes each piece of scene-driven work follows.
  ///
  /// Any scene: the `AppLifecycle` every sync service reads, server-address selection (a car-only
  /// drive is when the phone leaves the home network), the Focus-filter reconcile, podcast cloud
  /// sync, the iCloud settings refresh, and (once the last scene is backgrounded) the Watch context
  /// timestamp and the two background-task schedules. A car-only drive needs all of these; two
  /// scenes must not run any twice.
  ///
  /// Phone only: the position-tick cadence and sleep-timer Live Activity (CarPlay extrapolates
  /// elapsed time itself), the daily auto-backup into a phone-chosen folder, and the
  /// notification-settings refresh that picks up a Settings app change.
  static var production: Self {
    Self(
      lifecyclePhase: { phase in
        notingActivation("RootView.environment.handleScenePhase", when: phase == .active) {
          AppEnvironment.sharedLifecycle.handle(scenePhase: phase)
        }
      },
      phoneScenePhase: { phase in
        notingActivation("RootView.hardware.handleScenePhase", when: phase == .active) {
          PlaybackHardware.shared.handleScenePhase(phase)
        }
      },
      carConnectedWithoutPhone: {
        PlaybackHardware.shared.noteHeadlessEntry()
      },
      anySceneBecameActive: {
        AppRuntime.shared.endpointTriggers.sceneBecameActive()
        guard runsAppLevelWork else { return }
        notingActivation("WhirrApp.scenePhase.active-callbacks") {
          // A Focus that changed while Whirr was suspended or closed is not delivered.
          Task { await FocusPlaybackSpeedState.shared.reconcileWithFilter() }
          if let runtime = PodcastCloudSyncComposition.runtime {
            Task { await runtime.sceneDidBecomeActive() }
          }
          notingActivation("ICloudSettingsSync.refreshFromICloud") {
            ICloudSettingsSync.shared.refreshFromICloud()
          }
        }
      },
      phoneSceneBecameActive: {
        if runsAppLevelWork, PodcastDataSettingsReadiness.automaticBackups {
          // At most daily, and only when the user has chosen a folder.
          Task { await PodcastBackupComposition.autoBackupModel.runIfDue() }
        }
        notingActivation("RootView.podcastNotificationSettings.sceneDidBecomeActive") {
          AppRuntime.shared.current?.podcastNotificationSettingsModel.sceneDidBecomeActive()
        }
      },
      allScenesEnteredBackground: {
        AppRuntime.shared.endpointTriggers.allScenesEnteredBackground()
        guard runsAppLevelWork else { return }
        if let runtime = PodcastCloudSyncComposition.runtime {
          Task { await runtime.sceneDidEnterBackground() }
        }
        // The Watch context dedup timestamp is held in memory for the life of the process and
        // written through here, once, instead of on every catalogue publication.
        WatchCompanionRuntime.shared.persistContextTimestamp()
        PodcastBackgroundRefreshHardware.scheduleIfAuthenticated()
        AdSkipBackgroundAnalysis.schedule()
      })
  }

  /// The microstutter fixture measures the shell alone, without the app-level work around it.
  private static var runsAppLevelWork: Bool {
    #if PERF_INVESTIGATION
      !MicrostutterAblation.fixture
    #else
      true
    #endif
  }

  private static func notingActivation(
    _ label: String, when isActivation: Bool = true, _ body: () -> Void
  ) {
    #if PERF_INVESTIGATION
      let start = CACurrentMediaTime()
      body()
      if isActivation {
        MicrostutterProbe.shared.noteActivation(
          label, elapsed: CACurrentMediaTime() - start, startedAt: start)
      }
    #else
      body()
    #endif
  }
}
