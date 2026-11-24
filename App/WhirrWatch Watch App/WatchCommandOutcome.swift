import Foundation
import WatchProtocol

enum WatchCommandOutcome: Equatable {
  case sent
  case busy
  case phoneUnavailable
  case unresolved
  case rejected(WatchProtocolErrorCode)
}

extension WatchCommandOutcome {
  /// Each command gets a fresh event, even when successive outcomes are equal.
  struct Event: Equatable {
    let id = UUID()
    let outcome: WatchCommandOutcome
  }

  /// Delivery bookkeeping is silent; only a blocked action with a recovery step gets copy.
  func statusDescription() -> String? {
    switch self {
    case .sent, .busy, .unresolved:
      return nil
    case .phoneUnavailable:
      return "Open Whirr on your nearby iPhone, then try again."
    case .rejected(let code):
      return code == .audioActivationFailed
        ? "Choose headphones or speakers on your iPhone, then try again."
        : "Open Whirr on your iPhone to continue."
    }
  }
}
