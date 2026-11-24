import Foundation
import Testing

@testable import Whirr

/// The boundary's whole value is that it compares equal across a shell body evaluation that
/// changed nothing the Library cares about, and unequal the moment something it renders did
/// change. `Identity` carries exactly what `==` consults, so both halves are testable without a
/// live browse model.
@MainActor
@Suite("Library tab content boundary", .timeLimit(.minutes(1)))
struct LibraryTabContentTests {
  /// `Sendable` and `nonisolated` only so `identity`'s default argument can name one: a default
  /// argument is evaluated in a nonisolated context, and this suite is `@MainActor`. The stubs
  /// are inert identity tokens with no state to protect.
  private nonisolated final class Stub: Sendable {}

  private nonisolated static let selectionEntry = Stub()
  private nonisolated static let browseModel = Stub()
  private nonisolated static let downloadStatus = Stub()
  private nonisolated static let finishedStatus = Stub()
  private nonisolated static let actions = Stub()
  private nonisolated static let playback = Stub()
  private nonisolated static let relay = Stub()

  private func identity(
    mode: LibraryBrowsePresentation.Mode = .titles,
    scrollToTopRequest: Int = 0,
    browseModel: Stub = LibraryTabContentTests.browseModel
  ) -> LibraryTabContent.Identity {
    LibraryTabContent.Identity(
      mode: mode,
      scrollToTopRequest: scrollToTopRequest,
      selectionEntry: ObjectIdentifier(Self.selectionEntry),
      browseModel: ObjectIdentifier(browseModel),
      downloadStatus: ObjectIdentifier(Self.downloadStatus),
      finishedStatus: ObjectIdentifier(Self.finishedStatus),
      actions: ObjectIdentifier(Self.actions),
      playback: ObjectIdentifier(Self.playback),
      relay: ObjectIdentifier(Self.relay))
  }

  @Test("the same models and mode compare equal, so a shell body evaluation stops here")
  func unchangedInputsCompareEqual() {
    #expect(identity() == identity())
  }

  @Test("a browse mode change crosses the boundary")
  func modeChangeComparesUnequal() {
    #expect(identity(mode: .titles) != identity(mode: .authors))
  }

  @Test("a tab reselect crosses the boundary so the list can scroll to its top edge")
  func reselectRequestCrossesTheBoundary() {
    #expect(identity(scrollToTopRequest: 1) != identity(scrollToTopRequest: 2))
  }

  @Test("a replaced browse model crosses the boundary, which is how an account change arrives")
  func replacedBrowseModelComparesUnequal() {
    #expect(identity() != identity(browseModel: Stub()))
  }
}
