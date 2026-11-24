import Foundation

/// Seam over the filesystem move `DownloadFileStore` performs, which can fail with a real
/// disk-full error in production but cannot be forced to in a host unit test (like
/// `FileAttributeApplying`, whose Data Protection is only observable on-device). Production uses
/// `FileManager.default.moveItem`; tests inject a fake that throws an `ENOSPC`-shaped error.
public protocol DownloadFileMoving: Sendable {
  func moveItem(at sourceURL: URL, to destinationURL: URL) throws
}

/// Production `DownloadFileMoving` conformance: an ordinary `FileManager` move, an atomic rename
/// when source and destination share a volume (URLSession's temp file and the app container's
/// downloads root do).
public struct POSIXDownloadFileMover: DownloadFileMoving {
  public init() {}

  public func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
  }
}
