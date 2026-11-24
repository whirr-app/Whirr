import AppModel
import Persistence
import Testing

@testable import Whirr

@Suite("Native podcast shows view presentation")
struct NativePodcastShowsViewPresentationTests {
  @Test func sortModeLabelsAndMenuOrderStayStable() {
    #expect(
      NativePodcastShowsViewPresentation.sortModeMenuOrder
        == [.alphabetical, .mostRecent, .custom])
    #expect(
      NativePodcastShowsViewPresentation.sortModeMenuOrder.map(
        NativePodcastShowsViewPresentation.sortModeLabel)
        == ["Alphabetical", "Most Recent", "Custom"])
  }

  @Test func resetOrderIsOfferedOnlyForCustomMode() {
    #expect(NativePodcastShowsViewPresentation.resetIsOffered(mode: .alphabetical) == false)
    #expect(NativePodcastShowsViewPresentation.resetIsOffered(mode: .mostRecent) == false)
    #expect(NativePodcastShowsViewPresentation.resetIsOffered(mode: .custom))
  }

  @Test func placeholdersCoverLoadingEmptyAndLoadedStates() {
    #expect(
      NativePodcastShowsViewPresentation.placeholder(for: .loading)
        == .loading(message: NativePodcastShowsViewPresentation.loadingMessage))
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

  @Test func userFacingCopyStaysSourceNeutral() {
    let copy =
      [
        NativePodcastShowsViewPresentation.navigationTitle,
        NativePodcastShowsViewPresentation.sortMenuLabel,
        NativePodcastShowsViewPresentation.resetMenuActionLabel,
        NativePodcastShowsViewPresentation.resetConfirmationTitle,
        NativePodcastShowsViewPresentation.resetConfirmationMessage,
        NativePodcastShowsViewPresentation.resetConfirmationConfirmLabel,
        NativePodcastShowsViewPresentation.resetConfirmationCancelLabel,
        NativePodcastShowsViewPresentation.loadingMessage,
        NativePodcastShowsViewPresentation.emptyTitle,
        NativePodcastShowsViewPresentation.emptyMessage,
        NativePodcastShowsViewPresentation.unfollowConfirmationMessage,
        NativePodcastShowsViewPresentation.unfollowConfirmLabel,
      ]
      + NativePodcastShowsViewPresentation.sortModeMenuOrder.map(
        NativePodcastShowsViewPresentation.sortModeLabel)
    let lowered = copy.joined(separator: " ").lowercased()

    #expect(lowered.contains("rss") == false)
    #expect(lowered.contains("feed") == false)
    #expect(lowered.contains("audiobookshelf") == false)
  }

  @Test("edit mode exposes one confirmed per-show unfollow action")
  func editModeUnfollowPresentation() {
    #expect(NativePodcastShowsViewPresentation.showsUnfollowControl(isEditing: false) == false)
    #expect(NativePodcastShowsViewPresentation.showsUnfollowControl(isEditing: true))
    #expect(
      NativePodcastShowsViewPresentation.unfollowConfirmationTitle(showTitle: "The Daily")
        == "Unfollow “The Daily”?")
    #expect(
      NativePodcastShowsViewPresentation.unfollowAccessibilityLabel(showTitle: "The Daily")
        == "Unfollow The Daily")
  }

  @Test("Reduce Motion removes the edit-mode entrance cue")
  func editModeEntranceCueRespectsReduceMotion() {
    #expect(NativePodcastShowsViewPresentation.editModeEntranceCue(reduceMotion: false) == .scale)
    #expect(NativePodcastShowsViewPresentation.editModeEntranceCue(reduceMotion: true) == .none)
  }

  @Test("removing the final show ends edit mode")
  func finalShowRemovalEndsEditing() {
    #expect(NativePodcastShowsViewPresentation.shouldEndEditing(showCount: 0))
    #expect(NativePodcastShowsViewPresentation.shouldEndEditing(showCount: 1) == false)
  }

  @Test("unfollow confirmation cancellation and confirmation consume exactly one target")
  func unfollowConfirmationState() {
    var confirmation = NativePodcastUnfollowConfirmation()

    confirmation.request(itemID: "rss:1", title: "The Daily")
    #expect(confirmation.isPresented)
    confirmation.cancel()
    #expect(confirmation.target == nil)

    confirmation.request(itemID: "rss:2", title: "Today")
    #expect(
      confirmation.confirm()
        == NativePodcastUnfollowConfirmation.Target(itemID: "rss:2", title: "Today"))
    #expect(confirmation.confirm() == nil)
    #expect(confirmation.isPresented == false)
  }

}
