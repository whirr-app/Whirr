import Foundation
import Persistence

/// `DownloadFileMoving`'s fake: forces the move failures a host test cannot otherwise produce (a
/// full disk, a denied write). With no error stubbed it performs the real `FileManager` move, so a
/// success path still leaves a file where the store expects one.
public final class FakeDownloadFileMoving: DownloadFileMoving, @unchecked Sendable {
  /// One attempted move.
  public struct Move: Equatable, Sendable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
      self.source = source
      self.destination = destination
    }
  }

  /// An `ENOSPC` error, the disk-full condition `DownloadFileStore` classifies as `lowDisk`.
  public static var outOfSpace: any Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
  }

  /// An `EACCES` error, a write the process is not allowed to make.
  public static var permissionDenied: any Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
  }

  /// Every attempted move, in order, whether or not it threw.
  public let recorder = CallRecorder<Move>(label: "FakeDownloadFileMoving.moveItem")
  public var moves: [Move] { recorder.calls }

  private let errorBox: Locked<(any Error)?>

  /// - Parameter error: thrown by every move; `nil` performs the real move.
  public init(error: (any Error)? = nil) {
    errorBox = Locked(error)
  }

  /// Replaces the error every following move throws; `nil` goes back to the real move.
  public func stubError(_ error: (any Error)?) {
    errorBox.value = error
  }

  public func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
    recorder.record(Move(source: sourceURL, destination: destinationURL))
    if let error = errorBox.value { throw error }
    try POSIXDownloadFileMover().moveItem(at: sourceURL, to: destinationURL)
  }
}
