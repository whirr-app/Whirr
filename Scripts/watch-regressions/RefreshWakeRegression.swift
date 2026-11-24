import Foundation
import WatchProtocol

@main
struct RefreshWakeRegression {
  static func main() {
    wakeWithoutDeliveryWaits()
    deliveryReleases()
    graceReleases()
    pendingContentWaits()
    settlingPassWaits()
    midSettleDeliveryIsCounted()
    contentNamesAreRedacted()
    resetEndsTheWake()
    print("Watch refresh wake: release rule, grace, mid-settle deliveries and content names passed")
  }

  /// The device case: the refresh task arrived while the session was activated with no content
  /// pending, and it was released 12 ms later. The offer was delivered afterwards, so nothing had
  /// proved the wake's content arrived and the task must wait.
  private static func wakeWithoutDeliveryWaits() {
    let wake = WatchRefreshWake()
    precondition(wake.decision(activated: true, hasContentPending: false, settling: false) == .wait)
    // Activation is part of the rule even when content has already arrived.
    precondition(
      WatchRefreshWake(deliveredContent: true)
        .decision(activated: false, hasContentPending: false, settling: false) == .wait)
  }

  private static func deliveryReleases() {
    precondition(
      WatchRefreshWake(deliveredContent: true)
        .decision(activated: true, hasContentPending: false, settling: false) == .release)
    // A delivery does not release a wake that is still settling.
    precondition(
      WatchRefreshWake(deliveredContent: true)
        .decision(activated: true, hasContentPending: false, settling: true) == .wait)
  }

  private static func graceReleases() {
    // The quiet grace exists only for a wake that genuinely carried nothing.
    precondition(
      WatchRefreshWake(graceElapsed: true)
        .decision(activated: true, hasContentPending: false, settling: false) == .release)
    precondition(
      WatchRefreshWake(graceElapsed: true)
        .decision(activated: true, hasContentPending: false, settling: true) == .wait)
  }

  private static func pendingContentWaits() {
    // Undelivered content outranks both a delivery and the grace.
    for wake in [WatchRefreshWake(deliveredContent: true), WatchRefreshWake(graceElapsed: true)] {
      precondition(
        wake.decision(activated: true, hasContentPending: true, settling: false) == .wait)
    }
  }

  private static func settlingPassWaits() {
    for wake in [WatchRefreshWake(deliveredContent: true), WatchRefreshWake(graceElapsed: true)] {
      precondition(
        wake.decision(activated: true, hasContentPending: false, settling: true) == .wait)
    }
  }

  /// A delivery during a settle must earn another settle. The count is what the settle compares
  /// before and after; a flag could not tell an earlier delivery from a new one.
  private static func midSettleDeliveryIsCounted() {
    var wake = WatchRefreshWake(deliveredContent: true)
    let before = wake.deliveries
    wake.contentDelivered()
    precondition(wake.deliveries == before + 1)
    precondition(wake.deliveredContent)
  }

  private static func contentNamesAreRedacted() {
    let offer = WatchRefreshWake.content(in: [WatchTransportKey.episodeSendOffer: Data([0x01])])
    precondition(offer == .userInfo(key: "offer"))
    precondition(offer.diagnosticFields == ["kind": "userInfo", "key": "offer"])
    precondition(WatchRefreshWake.content(in: ["other": 1]) == .userInfo(key: "unknown"))
    let absOffer = WatchRefreshWake.content(in: [WatchTransportKey.absSendOffer: Data([0x01])])
    precondition(absOffer == .userInfo(key: "absOffer"))
    precondition(absOffer.diagnosticFields == ["kind": "userInfo", "key": "absOffer"])
    precondition(
      WatchRefreshWake.Content.applicationContext.diagnosticFields == ["kind": "context"])
    precondition(WatchRefreshWake.Content.message.diagnosticFields == ["kind": "message"])
    precondition(WatchRefreshWake.Content.file.diagnosticFields == ["kind": "file"])
  }

  private static func resetEndsTheWake() {
    var wake = WatchRefreshWake(deliveredContent: true, graceElapsed: true)
    wake.reset()
    precondition(wake == WatchRefreshWake())
    precondition(!wake.deliveredContent)
    precondition(wake.decision(activated: true, hasContentPending: false, settling: false) == .wait)
  }
}
