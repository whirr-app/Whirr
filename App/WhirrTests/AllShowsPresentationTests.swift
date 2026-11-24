import AppModel
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// The values both all-shows screens share: one placeholder type, one set of reset copy, and
/// one edit-mode animation rule.
@Suite("All-shows shared presentation")
struct AllShowsPresentationTests {

  @Test("loading and empty never intercept a drag, error is interactive with Retry")
  func placeholderInteractivity() {
    let loading = AllShowsPlaceholder.loading(message: "Loading")
    #expect(loading.allowsHitTesting == false)
    #expect(loading.action == nil)

    let empty = AllShowsPlaceholder.empty(title: "Empty", message: "None", systemImage: "x")
    #expect(empty.allowsHitTesting == false)
    #expect(empty.action == nil)

    let error = AllShowsPlaceholder.error(
      title: "Error", message: "Failed", systemImage: "x", action: .retry)
    #expect(error.allowsHitTesting)
    #expect(error.action == .retry)
    #expect(error.action?.label == "Retry")
  }

  @Test("the server screen maps its states onto the shared placeholder")
  func serverStatesUseSharedPlaceholder() {
    let loading: AllShowsPlaceholder? = PodcastShowsViewPresentation.placeholder(for: .loading)
    #expect(loading == .loading(message: PodcastShowsCopy.loading))
    #expect(
      PodcastShowsViewPresentation.placeholder(for: .empty)
        == .empty(
          title: "No Shows Yet", message: PodcastShowsCopy.empty,
          systemImage: "antenna.radiowaves.left.and.right"))
    #expect(
      PodcastShowsViewPresentation.placeholder(for: .error)
        == .error(
          title: "Couldn't Load Shows", message: PodcastShowsCopy.error,
          systemImage: "exclamationmark.triangle", action: .retry))
  }

  /// The followed screen keeps its own wording, as named constants.
  @Test("the followed screen maps its states onto the shared placeholder through named copy")
  func nativeStatesUseNamedCopy() {
    let loading: AllShowsPlaceholder? = NativePodcastShowsViewPresentation.placeholder(for: .loading)
    #expect(loading == .loading(message: NativePodcastShowsViewPresentation.loadingMessage))
    #expect(loading?.allowsHitTesting == false)
    #expect(
      NativePodcastShowsViewPresentation.placeholder(for: .empty)
        == .empty(
          title: NativePodcastShowsViewPresentation.emptyTitle,
          message: NativePodcastShowsViewPresentation.emptyMessage,
          systemImage: NativePodcastShowsViewPresentation.emptySystemImage))
    #expect(
      NativePodcastShowsViewPresentation.placeholder(
        for: .loaded(NativePodcastShowsSnapshot(mode: .custom, shows: []))) == nil)
  }

  @Test("both screens resolve the same reset copy")
  func resetCopyIsShared() {
    typealias Server = PodcastShowsViewPresentation
    typealias Native = NativePodcastShowsViewPresentation

    #expect(Server.resetMenuActionLabel == AllShowsResetCopy.menuActionLabel)
    #expect(Native.resetMenuActionLabel == AllShowsResetCopy.menuActionLabel)
    #expect(Server.resetConfirmationTitle == AllShowsResetCopy.title)
    #expect(Native.resetConfirmationTitle == AllShowsResetCopy.title)
    #expect(Server.resetConfirmationMessage == AllShowsResetCopy.message)
    #expect(Native.resetConfirmationMessage == AllShowsResetCopy.message)
    #expect(Server.resetConfirmationConfirmLabel == AllShowsResetCopy.confirmLabel)
    #expect(Native.resetConfirmationConfirmLabel == AllShowsResetCopy.confirmLabel)
    #expect(Server.resetConfirmationCancelLabel == AllShowsResetCopy.cancelLabel)
    #expect(Native.resetConfirmationCancelLabel == AllShowsResetCopy.cancelLabel)
  }

  /// One rule for both screens' Edit/Done, matching the native cue's Reduce Motion behaviour.
  @Test("the Edit/Done animation is snappy and disappears under Reduce Motion")
  func editModeAnimationRespectsReduceMotion() {
    #expect(PodcastShowsViewPresentation.editModeAnimation(reduceMotion: false) == .snappy)
    #expect(PodcastShowsViewPresentation.editModeAnimation(reduceMotion: true) == nil)
  }

}
