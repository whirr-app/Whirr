import Foundation

/// Loads sanitized JSON fixtures captured from a live server.
///
/// Fixtures are scrubbed before they land here: no token, username, title, author,
/// hostname, filesystem path, device id, or stable server id survives sanitization.
public enum Fixtures {
  public enum LoadError: Error, Equatable {
    case notFound(String)
  }

  /// Returns the raw bytes of a fixture bundled with this target.
  public static func data(named name: String, extension ext: String = "json") throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
      throw LoadError.notFound("\(name).\(ext)")
    }
    return try Data(contentsOf: url)
  }
}
