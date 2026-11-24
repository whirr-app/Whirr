import Testing

@testable import Whirr

@Suite("Podcast accessibility identifiers")
struct PodcastAccessibilityIDTests {
  @Test func rowIdentifiersIncludeStableEpisodeIdentity() {
    #expect(PodcastAccessibilityID.episodeRow(showID: "show", episodeID: "episode").contains("show"))
    #expect(PodcastAccessibilityID.episodeRow(showID: "show", episodeID: "episode").contains("episode"))
  }

  @Test func screenOrderPlacesSearchBetweenTheHeaderAndFilters() throws {
    let searchIndex = try #require(
      PodcastAccessibilityID.screenIdentifiers.firstIndex(
        of: PodcastAccessibilityID.episodeSearchField))
    let headerIndex = try #require(
      PodcastAccessibilityID.screenIdentifiers.firstIndex(of: PodcastAccessibilityID.showHeader))
    let filterIndex = try #require(
      PodcastAccessibilityID.screenIdentifiers.firstIndex(of: PodcastAccessibilityID.showFilter))

    #expect(headerIndex < searchIndex)
    #expect(searchIndex < filterIndex)
  }

  @Test func selectionIdentifiersArePinned() {
    #expect(PodcastAccessibilityID.selectionDownload == "podcast.selection.download")
    #expect(PodcastAccessibilityID.selectionMarkAsFinished == "podcast.selection.markAsFinished")
    #expect(PodcastAccessibilityID.selectionCancelServerSave == "podcast.selection.cancelServerSave")
    #expect(PodcastAccessibilityID.selectionSaveToServer == "podcast.selection.saveToServer")
    #expect(PodcastAccessibilityID.selectionActions == "podcast.selection.actions")
    #expect(PodcastAccessibilityID.selectionRemoveDownloads == "podcast.selection.removeDownloads")
  }

  /// The toolbar derives `all`/`done`/`begin` from the screen's prefix, so the extras must share it.
  @Test func selectionIdentifiersShareTheToolbarPrefix() {
    let root =
      SelectionChromePresentation.Screen.podcastEpisodes.accessibilityIdentifierPrefix + ".selection."
    for identifier in [
      PodcastAccessibilityID.selectionDownload,
      PodcastAccessibilityID.selectionMarkAsFinished,
      PodcastAccessibilityID.selectionCancelServerSave,
      PodcastAccessibilityID.selectionSaveToServer,
      PodcastAccessibilityID.selectionActions,
      PodcastAccessibilityID.selectionRemoveDownloads,
    ] {
      #expect(identifier.hasPrefix(root), Comment(rawValue: identifier))
    }
  }
}

@Suite("Filter picker identifiers")
struct FilterPickerAccessibilityIDTests {
  @Test func identifiersArePinned() {
    #expect(PodcastAccessibilityID.filterPicker == "podcasts.filterPicker")
    #expect(SavedAccessibilityID.filterPicker == "saved.filterPicker")
    #expect(HomeAccessibilityID.filterPicker == "home.filterPicker")
  }
}
