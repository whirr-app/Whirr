import Foundation
import WatchProtocol

/// One WatchConnectivity background wake: the state held from its first refresh task until those
/// tasks are completed.
///
/// A wake must not be released just because the session reports no content pending. watchOS hands
/// the refresh task over before WatchConnectivity delivers the user info that woke the app, so
/// releasing on `hasContentPending == false` alone lets the system suspend the app with the offer
/// still undelivered. The rule below holds the task until the content has been delivered, or until
/// the quiet grace shows the wake carried nothing this delegate can see.
nonisolated struct WatchRefreshWake: Equatable, Sendable {
  enum Decision: Equatable {
    case release
    case wait
  }

  /// What a wake delivered, named for the diagnostic line. Never the payload.
  enum Content: Equatable, Sendable {
    case userInfo(key: String)
    case applicationContext
    case message
    case file

    var diagnosticFields: [String: String] {
      switch self {
      case .userInfo(let key): return ["kind": "userInfo", "key": key]
      case .applicationContext: return ["kind": "context"]
      case .message: return ["kind": "message"]
      case .file: return ["kind": "file"]
      }
    }
  }

  /// How many deliveries this wake has seen. A settled pass compares it before and after, so content
  /// that arrived during the settle earns a second one instead of a release.
  private(set) var deliveries = 0
  private(set) var graceElapsed = false

  var deliveredContent: Bool { deliveries > 0 }

  init(deliveredContent: Bool = false, graceElapsed: Bool = false) {
    self.deliveries = deliveredContent ? 1 : 0
    self.graceElapsed = graceElapsed
  }

  mutating func contentDelivered() {
    deliveries &+= 1
  }

  mutating func graceDidElapse() {
    graceElapsed = true
  }

  mutating func reset() {
    self = WatchRefreshWake()
  }

  /// The release rule. `hasContentPending` covers content WatchConnectivity has not delivered yet,
  /// and `settling` covers a settle already in flight. Until either a delivery or the grace, nothing
  /// proves the wake's content arrived, so the tasks wait.
  func decision(activated: Bool, hasContentPending: Bool, settling: Bool) -> Decision {
    guard activated, !hasContentPending, !settling else { return .wait }
    return deliveredContent || graceElapsed ? .release : .wait
  }

  /// The episode offer and the Audiobookshelf offer are the user info the Watch handles. Any key
  /// still counts as a delivery; only a known key is named, so a log line can never carry a payload
  /// or an unknown key string.
  static func content(in userInfo: [String: Any]) -> Content {
    if userInfo[WatchTransportKey.episodeSendOffer] != nil { return .userInfo(key: "offer") }
    if userInfo[WatchTransportKey.absSendOffer] != nil { return .userInfo(key: "absOffer") }
    return .userInfo(key: "unknown")
  }
}
