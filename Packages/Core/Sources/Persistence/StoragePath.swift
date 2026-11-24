import Foundation

/// Pure path containment for files below the downloads root. Relative paths come from database
/// rows, so a corrupted row or a writer bug can contain `..` segments or an absolute path; every
/// removal site resolves a row's path through here and fails closed when it is not contained.
public enum StoragePath {
  /// `url`'s path relative to `root`, or `nil` when `url` is not strictly below `root`.
  public static func relativePath(of url: URL, under root: URL) -> String? {
    let rootPath = directoryPath(of: root)
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else { return nil }
    return String(path.dropFirst(rootPath.count))
  }

  /// Whether `relativePath` resolves strictly below `root`. Absolute paths and any `..` segment
  /// are rejected before standardisation can resolve them out of the root.
  public static func isContained(relativePath: String, under root: URL) -> Bool {
    guard relativePath.isEmpty == false, relativePath.hasPrefix("/") == false else { return false }
    guard
      relativePath.split(separator: "/", omittingEmptySubsequences: true).contains("..") == false
    else {
      return false
    }
    let resolved = root.appendingPathComponent(relativePath).standardizedFileURL.path
    return resolved.hasPrefix(directoryPath(of: root))
  }

  /// A root path with one trailing slash, so `hasPrefix` matches whole path components only.
  private static func directoryPath(of root: URL) -> String {
    let path = root.standardizedFileURL.path
    return path.hasSuffix("/") ? path : path + "/"
  }
}
