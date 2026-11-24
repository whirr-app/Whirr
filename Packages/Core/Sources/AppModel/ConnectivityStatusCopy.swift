import SyncEngine

/// User-facing copy for the shell's connectivity status indicator. The distinction between device
/// connectivity and an unresponsive server is deliberate: the first asks the user to reconnect,
/// while the second asks them to check their server and leaves reconnection to the app.
public struct ConnectivityStatusDescription: Sendable, Equatable {
  /// Doubles as the indicator's accessibility label. The indicator itself is a bare glyph, so this
  /// is the only wording VoiceOver has; it must name the problem rather than the symbol.
  public let title: String
  public let message: String
  public let systemImage: String
  public let retryTitle: String

  public init(title: String, message: String, systemImage: String, retryTitle: String) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.retryTitle = retryTitle
  }
}

/// Connectivity status copy belongs in AppModel so every surface renders the same remedy and
/// never embeds outage wording in a view.
public enum ConnectivityStatusCopy: Sendable {
  public static let retryTitle = "Retry"

  public static func status(for reason: ServerUnreachableReason) -> ConnectivityStatusDescription {
    switch reason {
    case .noNetworkPath:
      return ConnectivityStatusDescription(
        title: "You're Offline",
        message: "Reconnect to Wi-Fi or cellular data to reach Audiobookshelf.",
        systemImage: "wifi.slash",
        retryTitle: retryTitle)
    case .serverUnreachable:
      return ConnectivityStatusDescription(
        title: "Can't Reach Your Server",
        message: "Audiobookshelf isn't responding. Check your server; the app will reconnect when it can.",
        systemImage: "server.rack",
        retryTitle: retryTitle)
    }
  }
}
