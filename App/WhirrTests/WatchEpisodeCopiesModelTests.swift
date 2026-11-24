import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import Testing

@testable import Whirr

/// The phone's own half of Send to Watch. The model reaches the runtime that owns the Watch
/// transport through a host, so a suite can hold a model with no runtime attached at all.
@MainActor
@Suite("Watch episode copies model", .serialized)
struct WatchEpisodeCopiesModelTests {

  @Test func aConnectedHostSuppliesTheInstallStateAndOneAvailabilityRefresh() {
    let model = WatchEpisodeCopiesModel()
    var availabilityRefreshes = 0
    var sendRefreshes = 0
    model.connect(
      WatchEpisodeCopiesModel.Host(
        isWatchAppInstalled: { true },
        refreshAvailability: { availabilityRefreshes += 1 },
        refreshSend: { sendRefreshes += 1 }))

    model.refreshWatchAvailability()

    #expect(model.isWatchAppInstalled)
    #expect(availabilityRefreshes == 1)
    #expect(sendRefreshes == 0, "an availability read never plans a send")
  }

  @Test func withoutAHostTheModelReadsNoInstallAndAsksNothing() {
    let model = WatchEpisodeCopiesModel()

    model.refreshWatchAvailability()

    #expect(model.isWatchAppInstalled == false)
  }

  /// The host is read afresh on every refresh, so an answer from before the app was deleted cannot
  /// outlive it.
  @Test func aHostThatLosesTheAppClearsTheInstallState() {
    let model = WatchEpisodeCopiesModel()
    let installed = InstallAnswer()
    model.connect(
      WatchEpisodeCopiesModel.Host(
        isWatchAppInstalled: { installed.value }, refreshAvailability: {}, refreshSend: {}))
    model.refreshWatchAvailability()
    #expect(model.isWatchAppInstalled)

    installed.value = false
    model.refreshWatchAvailability()

    #expect(model.isWatchAppInstalled == false)
  }
}

/// A mutable answer the host closure reads on each call.
@MainActor
private final class InstallAnswer {
  var value = true
}
