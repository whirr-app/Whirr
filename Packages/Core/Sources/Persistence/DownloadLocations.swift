import Foundation

/// The one derivation of the downloads root shared by the download stores, account removal and
/// ad-skip's local-episode reader. Application Support, never Caches (SECURITY.md).
public enum DownloadLocations {
  public static let directoryName = "Downloads"

  public static func root(applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
  }
}
