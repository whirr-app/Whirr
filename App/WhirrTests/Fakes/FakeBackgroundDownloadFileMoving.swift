import Foundation

@testable import Whirr

/// Test double for `BackgroundDownloadFileMoving`. No real filesystem move happens. `errorToThrow`
/// drives the case where the mover fails and the adapter must report failure, never completion.
final class FakeBackgroundDownloadFileMoving: BackgroundDownloadFileMoving, @unchecked Sendable {
  private(set) var moveCalls: [(from: URL, to: URL)] = []
  var errorToThrow: Error?

  func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws {
    moveCalls.append((temporaryURL, destinationURL))
    if let errorToThrow {
      throw errorToThrow
    }
  }
}

struct FakeMoveError: Error, Equatable {
  let message: String
}
