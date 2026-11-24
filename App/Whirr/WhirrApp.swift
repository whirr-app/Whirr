//
//  WhirrApp.swift
//  Whirr
//
//  Created by Rhys Thomas on 21/07/2026.
//

import AppModel
import DesignSystem
import SwiftUI

@main
struct WhirrApp: App {
  // Wake-route bridge for background downloads. `appDelegate.adapter` and the `.backgroundTask`
  // modifier below both resolve to `BackgroundDownloadHardware.adapter`.
  @UIApplicationDelegateAdaptor(BackgroundDownloadAppDelegate.self) private var appDelegate

  // Memory metrics are a no-op unless `MemoryMetricsOptIn` is switched on. MetricKit delivers
  // payloads to the app and the figures are only logged locally. See `MetricKitMemorySubscriber`.
  init() {
    launchMark("app.init")
    #if DEBUG || PERF_INVESTIGATION
      if !UIHarness.isActive {
        launchSpan("app.init.watch") { WatchCompanionRuntime.shared.activate() }
      }
    #else
      WatchCompanionRuntime.shared.activate()
    #endif
    launchSpan("app.init.memoryMetrics") { MemoryMetricsHardware.startIfEnabled() }
    // Crash and hang diagnostics are kept locally for Settings › Report a Problem. Always on,
    // never transmitted. See `MetricKitDiagnosticsHardware`.
    launchSpan("app.init.metricKit") { MetricKitDiagnosticsHardware.start() }
    launchSpan("app.init.navAppearance") { AppAppearance.applyNavigationBarAppearance() }
    #if PERF_INVESTIGATION
      if !MicrostutterAblation.fixture { launchSpan("app.init.iCloudSettings") { ICloudSettingsSync.shared.start() } }
    #else
      ICloudSettingsSync.shared.start()
    #endif
    // BGTaskScheduler requires registration before launch finishes.
    launchSpan("app.init.adSkipRegister") { AdSkipBackgroundAnalysis.register() }
    #if DEBUG || PERF_INVESTIGATION
      if !UIHarness.isActive { LookBackTipConfiguration.configure() }
    #else
      LookBackTipConfiguration.configure()
    #endif
    launchMark("app.init.end")
  }

  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG || PERF_INVESTIGATION
          if UIHarness.isActive {
            UIHarnessRootView()
          } else {
            RootGate()
          }
        #else
          RootGate()
        #endif
      }
      // RootView owns the app appearance preference and the reader supplies its independent
      // presentation override.
      .tint(AppChrome.tint)
      // Ad skip is device-owned and idle while its setting is off; when it is on, the
      // coordinator follows the download tables for the life of the process.
      .task {
        #if DEBUG || PERF_INVESTIGATION
          guard !UIHarness.isActive else { return }
        #endif
        #if DEBUG
          // Waits for its own conditions, so it must not hold up the launch work below.
          Task { await TranscriptDebugTrigger.runIfArmed() }
        #endif
        await AdSkipComposition.runForLaunch()
        await PauseTrimComposition.runForLaunch()
        await TranscriptComposition.runForLaunch()
      }
      #if PERF_INVESTIGATION
        .onAppear {
          MicrostutterProbe.shared.startIfRequested()
          MicrostutterControl.startIfRequested()
          MicrostutterControl.startSelfScrollIfRequested()
        }
      #endif
      #if DEBUG
        // `WHIRR_REFRESH_WATCH=1` only. The refresh-control defect shows in the shipping shell,
        // which the harness screens cannot stand in for.
        .harnessRefreshWatch()
      #endif
      // A Focus change while Whirr was suspended or closed is not delivered, so the filter's
      // `.current` is read at launch, on each foreground (`SceneRegistry`) and at each play or
      // resume.
      .task {
        #if DEBUG || PERF_INVESTIGATION
          guard !UIHarness.isActive else { return }
        #endif
        let focus = FocusPlaybackSpeedState.shared
        let player = PlaybackHardware.shared.player
        focus.reconcileOnEachPlay(of: player)
        await focus.reconcileWithFilter()
      }
    }
    .backgroundTask(.urlSession(BackgroundDownloadHardware.sessionIdentifier)) { _ in
      // Touching the adapter recreates the session, which reattaches in-flight tasks; this route
      // and the `BackgroundDownloadAppDelegate` bridge share that one instance. Returning is this
      // route's completion signal, so it waits until the session's finishes are recorded.
      await BackgroundDownloadHardware.deliverWakeEvents()
    }
    .backgroundTask(.appRefresh(PodcastBackgroundRefreshHardware.identifier)) {
      await PodcastBackgroundRefreshHardware.handle()
    }
  }
}
