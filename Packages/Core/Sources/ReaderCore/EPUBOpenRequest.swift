import Foundation

/// The location at which an EPUB navigator should be initialized.
public enum EPUBInitialLocation: Sendable, Equatable {
  case position(ReadingPosition)
  case totalProgression(Double)
}

/// Everything the renderer needs to construct an EPUB navigator for an open.
public struct EPUBOpenRequest: Sendable, Equatable {
  public let localFileURL: URL
  public let preferences: ReaderPreferences
  public let initialLocation: EPUBInitialLocation?

  public init(
    localFileURL: URL,
    preferences: ReaderPreferences,
    initialLocation: EPUBInitialLocation?
  ) {
    self.localFileURL = localFileURL
    self.preferences = preferences
    self.initialLocation = initialLocation
  }
}
