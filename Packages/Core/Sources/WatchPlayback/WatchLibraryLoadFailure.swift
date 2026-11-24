import ABSApi
import Foundation
import WatchProtocol

/// Why the Watch could not list its server libraries, in terms the person can act on. The Watch
/// signs in to the server on its own, so a rejected pair or an unreachable address leaves the
/// phone working while the Watch has nothing to browse.
public enum WatchLibraryLoadFailure: Sendable, Equatable {
  case signInRejected
  case serverUnreachable
  case unavailable
  /// The request succeeded but the server has no library the Audiobooks destination can show.
  case noAudiobookLibrary

  /// Nil for cancellation and superseded requests, which are not failures to report.
  public init?(_ error: any Error) {
    switch error {
    case is CancellationError:
      return nil
    case let error as APIError:
      switch error {
      case .cancelled: return nil
      case .unauthorized, .forbidden: self = .signInRejected
      case .transport: self = .serverUnreachable
      default: self = .unavailable
      }
    case let error as WatchLibraryError:
      switch error {
      case .staleRequest: return nil
      case .notAuthenticated, .accountMismatch: self = .signInRejected
      default: self = .unavailable
      }
    case is TokenStoreError:
      self = .signInRejected
    case let error as URLError:
      if error.code == .cancelled { return nil }
      self = .serverUnreachable
    default:
      self = .unavailable
    }
  }

  /// What this failure proves about the Watch's link to its server, for the phone's status
  /// screen. Nil when it proves nothing, so the last known health should stand.
  public var linkHealth: WatchLinkHealth? {
    switch self {
    case .signInRejected: return .signInRejected
    case .serverUnreachable: return .serverUnreachable
    case .noAudiobookLibrary: return .healthy
    case .unavailable: return nil
    }
  }

  public var message: String {
    switch self {
    case .signInRejected:
      return """
        The server no longer accepts this Watch’s sign-in. Disconnect in Settings, then reconnect \
        from Whirr on iPhone.
        """
    case .serverUnreachable:
      return "Apple Watch couldn’t reach your server. Check the Watch is on a network that can reach it."
    case .unavailable:
      return "Couldn’t load your libraries. Try again."
    case .noAudiobookLibrary:
      return "This server has no audiobook library."
    }
  }
}
