import Foundation
import Testing

@testable import WatchPlayback
@testable import WatchProtocol

@Suite("Watch application context composer")
struct WatchApplicationContextComposerTests {
  private let playing = Data("playing-report".utf8)
  private let status = Data("status-report".utf8)

  @Test func aPlayingReportAloneProducesOnlyItsKey() {
    var composer = WatchApplicationContextComposer()
    composer.setPlayingReport(playing)

    let context = composer.applicationContext
    #expect(context.count == 1)
    #expect(context[WatchPlayingReport.transportKey] as? Data == playing)
  }

  @Test func aStatusReportAloneProducesOnlyItsKey() {
    var composer = WatchApplicationContextComposer()
    composer.setStatusReport(status)

    let context = composer.applicationContext
    #expect(context.count == 1)
    #expect(context[WatchStatusReport.transportKey] as? Data == status)
  }

  @Test func writingAStatusReportKeepsThePlayingReport() {
    var composer = WatchApplicationContextComposer()
    composer.setPlayingReport(playing)
    composer.setStatusReport(status)

    let context = composer.applicationContext
    #expect(context[WatchPlayingReport.transportKey] as? Data == playing)
    #expect(context[WatchStatusReport.transportKey] as? Data == status)
  }

  @Test func writingAPlayingReportKeepsTheStatusReport() {
    var composer = WatchApplicationContextComposer()
    composer.setStatusReport(status)
    composer.setPlayingReport(playing)

    let context = composer.applicationContext
    #expect(context[WatchStatusReport.transportKey] as? Data == status)
    #expect(context[WatchPlayingReport.transportKey] as? Data == playing)
  }

  @Test func replacingOneReportKeepsTheOtherAndTheNewestValue() {
    var composer = WatchApplicationContextComposer(playingReport: playing, statusReport: status)
    let newerPlaying = Data("newer-playing".utf8)
    let newerStatus = Data("newer-status".utf8)

    composer.setPlayingReport(newerPlaying)
    #expect(composer.applicationContext[WatchStatusReport.transportKey] as? Data == status)
    #expect(composer.applicationContext[WatchPlayingReport.transportKey] as? Data == newerPlaying)

    composer.setStatusReport(newerStatus)
    #expect(composer.applicationContext[WatchPlayingReport.transportKey] as? Data == newerPlaying)
    #expect(composer.applicationContext[WatchStatusReport.transportKey] as? Data == newerStatus)
  }

  @Test func clearingAReportRemovesItsKeyAndKeepsTheOther() {
    var composer = WatchApplicationContextComposer(playingReport: playing, statusReport: status)

    composer.setStatusReport(nil)
    #expect(composer.applicationContext.count == 1)
    #expect(composer.applicationContext[WatchPlayingReport.transportKey] as? Data == playing)

    composer.setPlayingReport(nil)
    #expect(composer.applicationContext.isEmpty)
  }
}

@Suite("Watch status report throttle")
struct WatchStatusReportThrottleTests {
  private let throttle = WatchStatusReportThrottle()
  private let stamp = try! WatchAccountStamp(
    accountIdentityHash: "account", serverIdentityHash: "server")
  private let now = Date(timeIntervalSinceReferenceDate: 10_000)

  private func report(
    stamp: WatchAccountStamp? = nil, health: WatchLinkHealth? = .healthy, checkedAt: Date? = nil,
    capabilities: Set<String> = [], at date: Date? = nil
  ) -> WatchStatusReport {
    try! WatchStatusReport(
      accountStamp: stamp ?? self.stamp, health: health, checkedAt: checkedAt, reportedAt: date ?? now,
      capabilities: capabilities)
  }

  @Test func theFirstReportAlwaysPublishes() {
    #expect(throttle.shouldPublish(report(), after: nil, at: now))
  }

  @Test func anUnchangedReportInsideTheWindowIsSkipped() {
    let first = report()
    let published = WatchStatusReportThrottle.Published(first)
    #expect(!throttle.shouldPublish(first, after: published, at: now.addingTimeInterval(60)))
    #expect(!throttle.shouldPublish(first, after: published, at: now.addingTimeInterval(14 * 60)))
  }

  @Test func anUnchangedReportPublishesAgainAtTheWindow() {
    let first = report()
    let published = WatchStatusReportThrottle.Published(first)
    #expect(throttle.shouldPublish(first, after: published, at: now.addingTimeInterval(15 * 60)))
    #expect(throttle.shouldPublish(first, after: published, at: now.addingTimeInterval(15 * 60 + 1)))
  }

  @Test func aChangedAccountHealthOrCapabilitiesPublishesAtOnce() {
    let first = report()
    let published = WatchStatusReportThrottle.Published(first)

    let otherAccount = try! WatchAccountStamp(
      accountIdentityHash: "other", serverIdentityHash: "server")
    #expect(
      throttle.shouldPublish(report(stamp: otherAccount), after: published, at: now.addingTimeInterval(1)))

    #expect(
      throttle.shouldPublish(
        report(health: .serverUnreachable), after: published, at: now.addingTimeInterval(1)))

    #expect(
      throttle.shouldPublish(
        report(capabilities: ["enclosureFetch"]), after: published,
        at: now.addingTimeInterval(1)))

    let signedOut = try! WatchStatusReport(accountStamp: nil, reportedAt: now.addingTimeInterval(1))
    #expect(throttle.shouldPublish(signedOut, after: published, at: now.addingTimeInterval(1)))
  }

  @Test func aNewCheckTimeAloneDoesNotPublish() {
    let first = report(checkedAt: now.addingTimeInterval(-600))
    let published = WatchStatusReportThrottle.Published(first)
    let later = report(checkedAt: now.addingTimeInterval(-60))

    #expect(!throttle.shouldPublish(later, after: published, at: now.addingTimeInterval(60)))
  }
}
