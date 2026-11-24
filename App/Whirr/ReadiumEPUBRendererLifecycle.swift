import ReaderCore

/// The three tap zones exposed by the navigator input observer.
enum ReadiumEPUBTapZone: Sendable, Equatable {
  case left
  case center
  case right
}

/// The pure lifecycle state machine kept separate from UIKit and Readium objects.
struct ReadiumEPUBRendererLifecycle: Equatable, Sendable {
  private(set) var state: EPUBRenderingLifecycleState = .stopped
  private(set) var activePublicationCount = 0

  mutating func start() {
    guard state == .stopped else { return }
    state = .ready
  }

  mutating func openSucceeded() {
    guard state != .stopped else { return }
    state = .publicationOpen
    activePublicationCount = 1
  }

  mutating func openFailed() {
    // The frozen boundary keeps the existing ready/publicationOpen state after a failed open.
  }

  mutating func close() {
    guard state == .publicationOpen else { return }
    state = .ready
    activePublicationCount = 0
  }

  mutating func stop() {
    state = .stopped
    activePublicationCount = 0
  }
}

enum ReadiumEPUBRendererError: Error, Equatable, Sendable {
  case noPublication
  case navigationFailed
}
