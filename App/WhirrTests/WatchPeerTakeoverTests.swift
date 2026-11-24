import AppModel
import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

/// The phone's reading of a Watch report as a takeover of its loaded, paused title: the Watch only
/// asks a playing phone to pause, so this is how the phone learns its position went stale.
@MainActor
struct WatchPeerTakeoverTests {
  private let phoneListened = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test func aReportNamingTheLoadedTitleAfterThePhoneListenedIsATakeover() throws {
    let loaded = try Self.loaded("book")
    for playing in [true, false] {
      let report = try Self.report("book", playing: playing, at: phoneListened.addingTimeInterval(60))
      #expect(
        WatchCompanionRuntime.takenOverSelection(report, loaded: loaded, phoneLastListened: { _, _ in phoneListened })
          == loaded)
    }
  }

  @Test func aReportFromBeforeThePhoneLastListenedIsNot() throws {
    let report = try Self.report("book", playing: false, at: phoneListened.addingTimeInterval(-60))
    #expect(
      WatchCompanionRuntime.takenOverSelection(
        report, loaded: try Self.loaded("book"), phoneLastListened: { _, _ in phoneListened }) == nil)
  }

  @Test func aReportForAnotherTitleOrNothingLoadedIsNot() throws {
    let report = try Self.report("other", playing: true, at: phoneListened.addingTimeInterval(60))
    #expect(
      WatchCompanionRuntime.takenOverSelection(
        report, loaded: try Self.loaded("book"), phoneLastListened: { _, _ in phoneListened }) == nil)
    #expect(
      WatchCompanionRuntime.takenOverSelection(report, loaded: nil, phoneLastListened: { _, _ in nil }) == nil)
  }

  @Test func aTitleWithNoStoredListenIsTakenOver() throws {
    let report = try Self.report("book", playing: true, at: phoneListened)
    let loaded = try Self.loaded("book")
    #expect(
      WatchCompanionRuntime.takenOverSelection(report, loaded: loaded, phoneLastListened: { _, _ in nil }) == loaded)
  }

  @Test("unbinding the account cancels an in-flight Watch takeover")
  func unbindCancelsAnInFlightTakeover() async {
    let runtime = WatchCompanionRuntime()
    let started = Mutex(false)
    let ran = Mutex(false)
    runtime.runTakeover {
      started.withLock { $0 = true }
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      ran.withLock { $0 = true }
    }
    let task = runtime.takeoverTaskForTesting
    let didStart = await awaitCondition("the takeover task starts") { started.withLock { $0 } }
    #expect(didStart == .observed)

    runtime.unbind(publishSignedOut: false)
    await task?.value
    #expect(ran.withLock { $0 } == false)
    #expect(runtime.takeoverTaskForTesting == nil)
  }

  private static func loaded(_ itemID: String) throws -> CompanionSelection {
    CompanionSelection(source: try #require(PodcastSourceIdentity(itemId: itemID)), episodeID: nil)
  }

  private static func report(_ itemID: String, playing: Bool, at date: Date) throws -> WatchPlayingReport {
    try WatchPlayingReport(
      accountStamp: WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server"),
      selection: WatchABSSelection(itemID: itemID, episodeID: nil), playing: playing, observedAt: date)
  }
}
