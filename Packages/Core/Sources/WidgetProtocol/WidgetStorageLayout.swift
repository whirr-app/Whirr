import Foundation

/// Where the app and the extension meet in the App Group container; both resolve paths here.
///
/// Everything lives under one folder, never the container root: account removal deletes the whole
/// folder (widgets plan, Publisher > Removal), and anything at the root would survive it.
public enum WidgetStorageLayout {
  /// Must match the `com.apple.security.application-groups` value the release audit pins.
  public static let appGroupIdentifier = "group.com.remoteconcern.whirr"
  public static let rootDirectoryName = "Widgets"
  public static let snapshotFileName = "snapshot.json"
  /// The smart list widget's file (`WidgetSmartLists`), beside the snapshot.
  public static let smartListsFileName = "smartLists.json"
  public static let coversDirectoryName = "Covers"
  /// Eight shelf items and four rows for each of at most four lists a widget shows, plus room for
  /// covers still referenced by a file the extension has not yet reloaded.
  public static let maxCoverFiles = 28
  public static let coverFileExtension = "jpg"

  public static func rootDirectory(inContainer container: URL) -> URL {
    container.appendingPathComponent(rootDirectoryName, isDirectory: true)
  }

  public static func snapshotFile(inContainer container: URL) -> URL {
    rootDirectory(inContainer: container).appendingPathComponent(snapshotFileName, isDirectory: false)
  }

  public static func smartListsFile(inContainer container: URL) -> URL {
    rootDirectory(inContainer: container).appendingPathComponent(smartListsFileName, isDirectory: false)
  }

  public static func coversDirectory(inContainer container: URL) -> URL {
    rootDirectory(inContainer: container).appendingPathComponent(coversDirectoryName, isDirectory: true)
  }

  /// The cover's URL, or a throw for any name the publisher could not have written. The extension
  /// reads files by the name the snapshot gives it, so a name that could leave the covers folder
  /// is refused here rather than trusted.
  public static func coverFile(named fileName: String, inContainer container: URL) throws -> URL {
    try validateCoverFileName(fileName)
    return coversDirectory(inContainer: container).appendingPathComponent(fileName, isDirectory: false)
  }

  /// A cover name is a token-shaped stem and the one extension: no separators, no dots in the
  /// stem, so no `..` and no path.
  public static func validateCoverFileName(_ fileName: String) throws {
    let suffix = ".\(coverFileExtension)"
    guard fileName.hasSuffix(suffix) else { throw WidgetProtocolError.invalidValue }
    let stem = fileName.dropLast(suffix.count)
    guard (1...64).contains(stem.utf8.count),
      stem.utf8.allSatisfy({ WidgetValidation.isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") })
    else { throw WidgetProtocolError.invalidValue }
  }
}
