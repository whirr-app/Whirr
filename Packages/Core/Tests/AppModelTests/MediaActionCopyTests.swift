import AppModel
import Testing

@Suite struct MediaActionCopyTests {
  /// Titles over the budget, each with the reason it is allowed to wrap.
  private static let overBudget: Set<String> = [
    // Shared with the shelf's feedback banner and Continue Reading's variant; it moves behind the
    // Progress submenu, where the extra line costs nothing.
    ContinueListeningCopy.action
  ]

  @Test func everyTitleFitsOneMenuLine() {
    for label in MediaActionCopy.all where Self.overBudget.contains(label.title) == false {
      #expect(
        label.title.count <= MediaActionCopy.menuTitleBudget,
        "\(label.title) is \(label.title.count) characters")
    }
  }

  /// Glyphs that deliberately mean the same thing. Any other repeat is a collision, as `bookmark`
  /// once was for both Add Bookmark and Save for Later.
  private static let sharedGlyphs: [String: Set<String>] = [
    "play.fill": ["Play", "Play Now"],
    "trash": ["Remove Download", "Remove Downloads", "Removing Download…", "Remove from Server"],
  ]

  @Test func noTwoActionsShareAGlyphUnlessListed() {
    let byGlyph = Dictionary(grouping: MediaActionCopy.all, by: \.systemImage)
    for (glyph, labels) in byGlyph where labels.count > 1 {
      #expect(Set(labels.map(\.title)) == Self.sharedGlyphs[glyph], "\(glyph) is shared")
    }
  }

  @Test func addBookmarkAndSaveForLaterLookDifferent() {
    #expect(MediaActionCopy.addBookmark.systemImage != MediaActionCopy.saveForLater.systemImage)
  }

  @Test func serverSaveTitlesAreShortAndShared() {
    #expect(NativeEpisodeServerSaveCopy.saveAction == MediaActionCopy.saveToServer.title)
    #expect(NativeEpisodeServerSaveCopy.removeAction == MediaActionCopy.removeFromServer.title)
    #expect(NativeEpisodeServerSaveCopy.saveSystemImage == MediaActionCopy.saveToServer.systemImage)
    #expect(NativeEpisodeServerSaveCopy.removeSystemImage == MediaActionCopy.removeFromServer.systemImage)
  }

  @Test func chapterSelectionCountsItsRows() {
    #expect(MediaActionCopy.addToUpNext(count: 0) == "Add to Up Next")
    #expect(MediaActionCopy.addToUpNext(count: 3) == "Add 3 to Up Next")
  }

  @Test func collectionSelectionTitlesComeFromTheTable() {
    let expected: [LibraryCollectionSelectionAction: String] = [
      .download: MediaActionCopy.download.title,
      .markAsFinished: MediaActionCopy.markAsFinished.title,
      .resetProgress: MediaActionCopy.resetProgress.title,
      .addToUpNext: MediaActionCopy.addToUpNext.title,
      .saveForLater: MediaActionCopy.saveForLater.title,
      .removeDownload: MediaActionCopy.removeDownloads.title,
    ]
    for action in LibraryCollectionSelectionAction.allCases {
      #expect(action.title == expected[action])
    }
  }
}
