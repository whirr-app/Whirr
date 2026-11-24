import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Minimal `HTTPClienting` fake, so a real `CoverImageClient` can run without network access.
/// Always answers with the same canned image bytes, whatever the request.
final class FakeCoverHTTPClient: HTTPClienting, @unchecked Sendable {
  private let imageData: Data
  /// Captured so a test can assert on the actual pixel width a request carried, not merely that a
  /// fetch happened.
  private(set) var lastRequest: HTTPRequest?
  private(set) var requestCount = 0

  init(imageData: Data) {
    self.imageData = imageData
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requestCount += 1
    lastRequest = request
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: imageData)
  }
}
