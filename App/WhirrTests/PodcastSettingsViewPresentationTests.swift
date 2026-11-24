import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// Model-level copy and behaviour are pinned by `PodcastSettingsModelTests` in Core. These tests
/// pin what `PodcastSettingsView` itself commits to: the picker choices it offers, and that its
/// cellular toggle stays visibly distinct from the manual-download cellular opt-in.
@Suite("Podcast settings presentation")
struct PodcastSettingsViewPresentationTests {
  /// Naming the episode outcome keeps these controls distinct from both manual downloads and the
  /// server's read-only setting, without a paragraph under either toggle.
  @Test func podcastSettingsCopyNamesEpisodeDownloadsDirectly() {
    #expect(PodcastDownloadCopy.autoDownloadToggleTitle.contains("Auto-download") == false)
  }

  /// The global Keep Latest picker offers 1, 3, 5, 10 and All. Never a sixth choice, which
  /// would need a new named policy value, and never fewer.
  @Test func keepLatestOffersTheNamedChoices() {
    #expect(PodcastSettingsViewPresentation.keepLatestChoices == [1, 3, 5, 10, 0])
    #expect(
      PodcastSettingsViewPresentation.keepLatestChoices.map(PodcastDownloadCopy.keepLatestValueLabel)
        == ["1", "3", "5", "10", "All"])
  }

  /// The `DownloadPreferences.allowCellular` toggle already sits in `SettingsView`'s Downloads
  /// section. This device feature's own cellular opt-in must never read as the same control, since
  /// consenting to spend data on a download you tapped is not consent to spend it on downloads you
  /// did not tap.
  @Test func cellularAutoDownloadToggleIsDistinctFromTheRule25Toggle() {
    #expect(PodcastDownloadCopy.allowCellularToggleTitle != SettingsCopy.cellularDownloadsToggleTitle)
  }

  /// Settings keeps its own two section headings. It never reuses the merged root's single heading
  /// or its tile-provenance copy for its two-section list.
  @Test func settingsOwnsItsOwnTwoSectionTitles() {
    #expect(
      PodcastSettingsViewPresentation.followedSectionTitle
        != PodcastSettingsViewPresentation.serverSectionTitle)
  }

  @Test func showRowsSplitBySourceAndKeepTheirArrivalOrder() {
    let rows = [
      Self.summary(itemID: "abs-b"), Self.summary(itemID: "rss:2"),
      Self.summary(itemID: "abs-a"), Self.summary(itemID: "rss:1"),
    ]

    let partitioned = PodcastSettingsViewPresentation.partitionedShowRows(
      rows, nativeSubscriptionsEnabled: true)

    #expect(partitioned.native.map(\.itemID) == ["rss:2", "rss:1"])
    #expect(partitioned.server.map(\.itemID) == ["abs-b", "abs-a"])
  }

  @Test func disablingNativeSubscriptionsHidesButDoesNotReclassifyFeedRows() {
    let rows = [Self.summary(itemID: "rss:1"), Self.summary(itemID: "abs-a")]

    let hidden = PodcastSettingsViewPresentation.partitionedShowRows(
      rows, nativeSubscriptionsEnabled: false)
    let restored = PodcastSettingsViewPresentation.partitionedShowRows(
      rows, nativeSubscriptionsEnabled: true)

    #expect(hidden.native.isEmpty)
    #expect(hidden.server.map(\.itemID) == ["abs-a"])
    #expect(restored.native.map(\.itemID) == ["rss:1"])
  }

  /// An account whose podcasts all come from one source gets one plain defaults section. There is
  /// no source switch, so no control is hidden behind a source the user is not using.
  @Test func downloadsShowsOnlyTheSourcesThatHaveShows() {
    let direct = [Self.summary(itemID: "rss:1")]
    let server = [Self.summary(itemID: "abs-a")]

    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: direct, nativeSubscriptionsEnabled: true, hasDirectFeedDefaults: true)
        == [.direct])
    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: server, nativeSubscriptionsEnabled: true, hasDirectFeedDefaults: true)
        == [.server])
  }

  /// Both sections appear together only when both stores are in use, or when neither is yet. An
  /// account with no podcasts has no reason to be steered to one source's defaults.
  @Test func downloadsShowsBothSourcesWhenBothOrNeitherHaveShows() {
    let both = [Self.summary(itemID: "rss:1"), Self.summary(itemID: "abs-a")]

    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: both, nativeSubscriptionsEnabled: true, hasDirectFeedDefaults: true)
        == [.direct, .server])
    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: [], nativeSubscriptionsEnabled: true, hasDirectFeedDefaults: true)
        == [.direct, .server])
  }

  /// Without a direct-feed store to write to (the toggle is off, or the build has no native
  /// settings access), the screen shows only the account's own defaults. Direct-feed rows must
  /// never create a section with nowhere to save.
  @Test func downloadsFallsBackToTheAccountDefaultsWithoutADirectFeedStore() {
    let both = [Self.summary(itemID: "rss:1"), Self.summary(itemID: "abs-a")]

    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: both, nativeSubscriptionsEnabled: false, hasDirectFeedDefaults: true)
        == [.server])
    #expect(
      PodcastSettingsViewPresentation.downloadDefaultsScopes(
        showRows: both, nativeSubscriptionsEnabled: true, hasDirectFeedDefaults: false)
        == [.server])
  }

  @Test func malformedReservedIDsAreNeverPresentedAsNativeShows() {
    let rows = ["rss:0", "RSS:1", "rss:abc", "rss:"].map(Self.summary(itemID:))

    let partitioned = PodcastSettingsViewPresentation.partitionedShowRows(
      rows, nativeSubscriptionsEnabled: true)

    #expect(partitioned.native.isEmpty)
    #expect(partitioned.server.count == rows.count)
  }

  nonisolated private static func summary(itemID: String) -> PodcastShowSettingsSummary {
    PodcastShowSettingsSummary(
      itemID: itemID, title: itemID, autoDownloadOverride: .inherit,
      effective: PodcastEffectiveSettings(
        isEnabled: false, keepLatestCount: 3, deleteAfterPlayed: false,
        floor: .distantPast))
  }
}
