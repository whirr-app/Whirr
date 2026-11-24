import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct ReaderTraceLabelTests {

  private static let projectionStates: [ReaderState] = [
    .noEpubAdvertised,
    .ebookIdentityNotFetched,
    .advertisedButUnavailable,
    .availableNotDownloaded,
    .downloading(progress: 0.5),
    .downloadHeld(reason: .waitingForWiFi, progress: 0),
    .downloadHeld(reason: .paused, progress: 0),
    .downloadHeld(reason: .pausedAuth, progress: 0),
    .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")),
    .downloadedButFileMissing,
    .downloadFailed,
  ]

  private static let modelStates: [ReaderModel.State] = [
    .idle,
    .downloading(progress: 0.5),
    .downloadHeld(reason: .waitingForWiFi),
    .downloadHeld(reason: .paused),
    .downloadHeld(reason: .pausedAuth),
    .opening,
    .reading,
    .unavailable,
    .drmProtected,
    .recoverableError,
    .unopenable,
    .publicationServerFailure,
  ]

  /// A trace whose states collide is worse than no trace: the whole point is telling apart outcomes
  /// that look identical on screen.
  @Test("every projection state has a distinct label")
  func projectionLabelsAreDistinct() {
    let labels = Self.projectionStates.map(ReaderTraceLabel.label(for:))
    #expect(Set(labels).count == Self.projectionStates.count)
    #expect(labels.allSatisfy { $0.isEmpty == false })
  }

  @Test("every model state has a distinct label")
  func modelLabelsAreDistinct() {
    let labels = Self.modelStates.map(ReaderTraceLabel.label(for:))
    #expect(Set(labels).count == Self.modelStates.count)
    #expect(labels.allSatisfy { $0.isEmpty == false })
  }

  /// Progress is a separate field, so a bar ticking from 1% to 99% must not look like 99 state
  /// changes. The model's change-only emission depends on it.
  @Test("progress does not vary a label")
  func progressDoesNotVaryALabel() {
    #expect(
      ReaderTraceLabel.label(for: ReaderState.downloading(progress: 0.1))
        == ReaderTraceLabel.label(for: ReaderState.downloading(progress: 0.9)))
    #expect(
      ReaderTraceLabel.label(for: ReaderModel.State.downloading(progress: 0.1))
        == ReaderTraceLabel.label(for: ReaderModel.State.downloading(progress: 0.9)))
  }
}
