import AppModel
import Testing

@Suite struct MediaItemMenuLayoutTests {
  private typealias Layout = MediaItemMenuLayout

  /// Folds into a readable string per row, so a test reads as the menu it describes.
  private static func fold(_ actions: [MediaItemAction]) -> [String] {
    Layout.fold(actions.map { (action: $0, row: $0.actionID) }) { fold, members in
      "\(fold.id)[\(members.joined(separator: ","))]"
    }
  }

  @Test func twoOrMoreProgressEntriesFoldIntoOneSubmenu() {
    #expect(
      Self.fold([.markAsFinished, .resetProgress, .removeFromContinueListening])
        == ["submenu.progress[mark-as-finished,reset-progress,remove-from-continue-listening]"])
    #expect(
      Self.fold([.resetProgress, .removeFromContinueListening])
        == ["submenu.progress[reset-progress,remove-from-continue-listening]"])
  }

  /// A submenu of one costs a tap and saves no row.
  @Test func aSingleProgressEntryStaysARow() {
    #expect(Self.fold([.markAsFinished]) == ["mark-as-finished"])
  }

  @Test func theSubmenuTakesItsFirstEntrysPlace() {
    #expect(
      Self.fold([.download, .markAsFinished, .resetProgress, .removeDownload])
        == ["download", "submenu.progress[mark-as-finished,reset-progress]", "remove-download"])
  }

  /// Transcript is a frequent action, so it is never behind a submenu (owner constraint). Look
  /// Back is not an item-menu action; the player overflow pins it the same way.
  @Test func navigationEntriesNeverFold() {
    let neverFolded: [MediaItemAction] = [
      .transcript, .openShow, .moreFrom, .moreFromCreator, .viewDetails, .read,
    ]
    for action in neverFolded {
      #expect(Layout.fold(for: action) == nil, "\(action) folded")
    }
    #expect(Self.fold([.transcript, .openShow]) == ["transcript", "open-show"])
  }

  @Test func onlyTheQueueAndProgressEntriesFold() {
    let grouped = Set(MediaItemAction.allCases.filter { Layout.fold(for: $0) == .controlGroup })
    let submenu = Set(
      MediaItemAction.allCases.filter { Layout.fold(for: $0) == .submenu(.progress) })
    #expect(grouped == [.playPause, .playNext, .addToUpNext])
    #expect(submenu == [.markAsFinished, .resetProgress, .removeFromContinueListening])
  }

  /// Play and the queue pair draw as one horizontal row, as Apple Music's do; Read stays a row.
  @Test func theQueueActionsBecomeOneControlGroup() {
    #expect(
      Self.fold([.playPause, .playNext, .addToUpNext, .read])
        == ["group.queue[play-pause,play-next,add-up-next]", "read"])
    #expect(Self.fold([.playNext, .addToUpNext]) == ["group.queue[play-next,add-up-next]"])
    #expect(Self.fold([.playPause]) == ["play-pause"])
  }

  /// "Add to Up Next" wraps under its glyph in the top row, so only there it reads "Play Last".
  @Test func onlyAddToUpNextHasACompactTitle() {
    let compact = MediaItemAction.allCases.filter { Layout.compactTitle(for: $0) != nil }
    #expect(compact == [.addToUpNext])
    #expect(Layout.compactTitle(for: .addToUpNext) == MediaActionCopy.addToUpNext.compactTitle)
  }

  @Test func theSubmenuTitleComesFromTheTable() {
    #expect(Layout.Submenu.progress.label == MediaActionCopy.progress)
    #expect(MediaActionCopy.progress.title.count <= MediaActionCopy.menuTitleBudget)
  }

  /// A downloaded audiobook's browse menu, as the menu draws it: 10 entries become 6 elements.
  @Test func aFullBookMenuLosesFourRows() {
    let state = BookMenuPresentation.State(
      capability: .audio, isSaved: false, queueAvailability: .both, playbackStatus: .inProgress,
      downloadAction: .remove, canSendToEreader: true)
    let sections = BookMenuPresentation.actionSections(state, surface: .browse)
    let rows = sections.map { section in Self.fold(section.actions) }
    #expect(sections.flatMap(\.actions).count == 10)
    #expect(rows.flatMap { $0 }.count == 6)
    #expect(rows.last == ["remove-download"])
  }
}
