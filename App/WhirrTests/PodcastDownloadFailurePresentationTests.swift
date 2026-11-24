import AppModel
import DesignSystem
import Persistence
import Testing

@testable import Whirr

/// The failed-download control's one behavior, pinned where both surfaces read it. Before this
/// type existed the show row's warning triangle was an ordinary Resume button: a tap retried at
/// once, and the only place the reason lived was VoiceOver's row value.
@Suite struct PodcastDownloadFailurePresentationTests {
  private static let failures: [DownloadErrorCategory] = [
    .transport, .auth, .validation, .storage, .lowDisk, .unknown,
  ]

  /// Every failure category gets the explain-first control; every other state gets nothing here
  /// and falls through to its ordinary status-derived action.
  @Test func onlyAFailedDownloadGetsTheExplainFirstControl() {
    for category in Self.failures {
      let control = PodcastDownloadFailurePresentation.control(for: .failed(category: category))
      #expect(control?.id == PodcastEpisodeViewAction.explainDownloadFailure.rawValue)
      #expect(control?.label == PodcastDownloadFailurePresentation.controlLabel)
      #expect(control?.hint == PodcastDownloadFailurePresentation.controlHint)
    }
    for status in [
      ItemDownloadStatus.notDownloaded, .waitingForWiFi, .queued, .downloading(progressFraction: 0.5),
      .paused, .pausedAuth, .interrupted, .deleting, .completed,
    ] {
      #expect(PodcastDownloadFailurePresentation.control(for: status) == nil)
    }
  }

  /// The control's id maps to no model action: a tap presents, it never performs.
  @Test func theControlsTapIsNotAModelAction() {
    #expect(
      AppModel.MediaItemAction(
        actionID: PodcastEpisodeViewAction.explainDownloadFailure.rawValue) == nil)
  }

  /// The alert says what went wrong in the category's own words, under a title that does not
  /// repeat inside the message, and carries the row's own retry.
  @Test func theAlertCarriesTheCategoryReasonAndTheRowsRetry() throws {
    var messages: Set<String> = []
    for category in Self.failures {
      let alert = try #require(
        PodcastDownloadFailurePresentation.alert(
          for: .failed(category: category), episodeID: "episode-1", isAvailableOnServer: false))
      #expect(alert.episodeID == "episode-1")
      #expect(alert.category == category)
      #expect(alert.retryAction == .resumeDownload)
      #expect(alert.message == ItemDownloadCopy.failureReason(category: category))
      #expect(alert.message.hasPrefix("Download failed") == false)
      #expect(ItemDownloadCopy.failed(category: category).hasSuffix(alert.message))
      messages.insert(alert.message)
    }
    #expect(messages.count == Self.failures.count, "no two categories share a reason")
    #expect(
      PodcastDownloadFailurePresentation.alert(
        for: .paused, episodeID: "episode-1", isAvailableOnServer: true) == nil)
  }

  /// Validation covers several causes, none of them a stale feed length, so the copy names no
  /// mismatch with anything and exposes nothing about the feed.
  @Test func validationCopyNoLongerClaimsAMismatch() {
    let reason = ItemDownloadCopy.failureReason(category: .validation)
    #expect(reason.localizedCaseInsensitiveContains("mismatch") == false)
    #expect(reason.localizedCaseInsensitiveContains("match") == false)
    #expect(ItemDownloadCopy.shortFailed(category: .validation) == "Failed, invalid file")
    #expect(reason.contains("http") == false)
    #expect(reason.contains("/") == false)
  }

  /// Try Again dispatches exactly one retry; Cancel dispatches none.
  @Test func tryAgainDispatchesExactlyOneRetryAndCancelDispatchesNone() throws {
    let alert = try #require(
      PodcastDownloadFailurePresentation.alert(
        for: .failed(category: .validation), episodeID: "episode-1", isAvailableOnServer: false))
    #expect(PodcastDownloadFailurePresentation.actions(for: .tryAgain, alert: alert) == [.resumeDownload])
    #expect(PodcastDownloadFailurePresentation.actions(for: .cancel, alert: alert).isEmpty)
  }

  /// The show row and the episode card answer a failed download identically: the same control
  /// (label, hint, id) and the same retry behind it, for every category.
  @Test func theShowRowAndTheEpisodeCardAgreeOnTheFailedControl() throws {
    for category in Self.failures {
      let status = ItemDownloadStatus.failed(category: category)
      let row = PodcastShowViewPresentation.episode(
        PodcastShowViewPresentationTests.episode(downloadStatus: status), queueAvailability: .both)
      let card = PodcastEpisodeCardViewPresentation.downloadControl(
        for: PodcastEpisodeCardViewPresentationTests.cardPresentation(downloadStatus: status))

      let expected = try #require(PodcastDownloadFailurePresentation.control(for: status))
      #expect(row.downloadAction == expected)
      #expect(card.action == expected)
      #expect(card.episodeAction == .resumeDownload)
      #expect(row.deviceStatus == card.deviceStatus)
      // The menu's own retry route survives on both surfaces.
      #expect(row.actions.map(\.id).contains(PodcastEpisodeViewAction.resumeDownload.rawValue))
      #expect(
        PodcastEpisodeCardViewPresentation.deviceActions(
          for: PodcastEpisodeCardViewPresentationTests.cardPresentation(downloadStatus: status)
        ).contains(.resumeDownload))
    }
  }

  /// VoiceOver hears the warning on the control and is told the tap explains; the row's value
  /// still carries the short reason, and the retry is reachable through the alert and the menu.
  @Test func voiceOverHearsTheWarningAndIsPointedAtTheRetry() {
    let control = PodcastDownloadFailurePresentation.control(for: .failed(category: .transport))
    #expect(control?.label == "Download failed")
    #expect(control?.hint.localizedCaseInsensitiveContains("try again") == true)
    #expect(control?.hint.localizedCaseInsensitiveContains("why") == true)
    let row = PodcastShowViewPresentation.episode(
      PodcastShowViewPresentationTests.episode(downloadStatus: .failed(category: .transport)),
      queueAvailability: .both)
    #expect(row.deviceStatus.text == ItemDownloadCopy.shortFailed(category: .transport))
    #expect(row.actions.first { $0.id == PodcastEpisodeViewAction.resumeDownload.rawValue }?.label == "Resume Download")
  }

}
