import AppModel
import DesignSystem
import SyncEngine
import Testing

@testable import Whirr

/// The shared long-press menu's rows, for books and episodes, as the values `MediaActionMenuItems`
/// draws.
@Suite("Item menu rows")
struct ItemContextMenuRowsTests {
  private typealias Presentation = ItemContextMenuPresentation
  private typealias Context = ItemContextMenuPresentation.RowContext

  private static let play = Presentation.playbackButton(isActiveItem: false, isPlaybackIntended: false)
  private static let pause = Presentation.playbackButton(isActiveItem: true, isPlaybackIntended: true)

  private static func bookContext(
    formats: [ItemDownloadFormat] = [.audio],
    delivery: EbookDeliveryMenuEntry? = nil,
    sending: Set<String> = [],
    creator: String? = "Books by Ursula K. Le Guin",
    narrator: String? = "Narrated by Ann Narrator",
    usesEbookProgress: Bool = false
  ) -> Context {
    Context(
      isEpisode: false, playback: play, downloadFormats: formats, delivery: delivery,
      sendingDeviceNames: sending, creatorLabel: creator, narratorLabel: narrator,
      usesEbookProgress: usesEbookProgress)
  }

  /// The rows a person can choose: a submenu's parent opens it and dispatches nothing.
  private static func leafIDs(_ rows: [MediaContextAction]) -> [String] {
    rows.flatMap { $0.isSubmenu ? leafIDs($0.children) : [$0.id] }
  }

  @Test func everySelectionIDRoundTrips() {
    let selections: [ItemMenuSelection] =
      MediaItemAction.allCases.map { .action($0) }
      + [ItemDownloadFormat.audio, .ebook, .both].map { .downloadFormat($0) }
      + [
        .sendToEreader(deviceName: "Kindle: Rhys"), .creatorLink, .narratorLink, .closingAction,
        .sendToWatchAnyway,
      ]
    for selection in selections {
      #expect(ItemMenuSelection(id: selection.id) == selection)
    }
    #expect(Set(selections.map(\.id)).count == selections.count)
  }

  @Test func browseBookMenuDrawsEverySectionThroughTheTable() {
    let state = BookMenuPresentation.State(
      capability: .audioAndEbook, isSaved: false, queueAvailability: .both,
      playbackStatus: .inProgress, canSendToEreader: true)
    let context = Self.bookContext(
      formats: ItemMediaCapability.audioAndEbook.downloadFormats,
      delivery: .single(EbookDeliveryDevice(name: "Kindle")))
    let rows = Presentation.menuSections(
      BookMenuPresentation.actionSections(state, surface: .browse), context: context)

    #expect(
      rows.map { $0.map(\.label) } == [
        ["", "Read"],
        ["Save for Later"],
        [MediaActionCopy.moreFrom.title],
        ["Download"],
        [MediaActionCopy.progress.title],
        ["Send to Kindle"],
      ])
    // Play and the queue pair are one horizontal row, as in Apple Music.
    #expect(rows[0].first?.childrenStyle == .controlGroup)
    #expect(rows[0].first?.children.map(\.label) == ["Play", "Play Next", "Add to Up Next"])
    // The group draws the compact title; VoiceOver keeps `label`.
    #expect(
      rows[0].first?.children.map(\.compactLabel)
        == [nil, nil, MediaActionCopy.addToUpNext.compactTitle])
    #expect(
      rows[4].first?.children.map(\.label)
        == ["Mark as Finished", "Reset Progress", "Remove from Continue Listening"])
    // Every row and every submenu choice dispatches to something.
    for id in Self.leafIDs(rows.flatMap { $0 }) {
      #expect(ItemMenuSelection(id: id) != nil, "\(id) dispatches to nothing")
    }
  }

  /// Outside the group, Add to Up Next keeps its full title.
  @Test func aLoneQueueRowKeepsItsFullTitle() throws {
    let row = try #require(Presentation.row(.addToUpNext, context: Self.bookContext()))
    let folded = Presentation.foldedRows([(action: .addToUpNext, row: row)])
    #expect(folded.count == 1)
    #expect(folded.first?.compactLabel == nil)
    #expect(folded.first?.label == MediaActionCopy.addToUpNext.title)
  }

  /// The presented menu resolves Play/Pause; the row only carries what it was given.
  @Test func playRowTakesTheResolvedTitle() {
    let paused = Presentation.row(
      .playPause, context: Context(isEpisode: true, playback: Self.pause))
    #expect(paused?.label == MediaActionCopy.pause.title)
    #expect(paused?.systemImage == MediaActionCopy.pause.systemImage)
  }

  @Test func mixedMediaDownloadAsksForAFormat() {
    let mixed = Presentation.row(
      .download, context: Self.bookContext(formats: [.audio, .ebook, .both]))
    #expect(mixed?.isSubmenu == true)
    #expect(mixed?.children.map(\.id) == ["download.audio", "download.ebook", "download.both"])

    let single = Presentation.row(.download, context: Self.bookContext(formats: [.ebook]))
    #expect(single?.isSubmenu == false)
    #expect(single?.id == ItemMenuSelection.downloadFormat(.ebook).id)

    let episode = Presentation.row(.download, context: Context(isEpisode: true, playback: Self.play))
    #expect(episode?.id == MediaItemAction.download.actionID)
  }

  @Test func authorAndNarratorShareOneSubmenu() {
    let both = Presentation.row(.moreFrom, context: Self.bookContext())
    #expect(both?.label == MediaActionCopy.moreFrom.title)
    #expect(both?.children.map(\.id) == ["more-from.creator", "more-from.narrator"])
    #expect(both?.children.allSatisfy { $0.titleLineLimit == 1 } == true)

    let authorOnly = Presentation.row(.moreFrom, context: Self.bookContext(narrator: nil))
    #expect(authorOnly?.isSubmenu == false)
    #expect(authorOnly?.label == "Books by Ursula K. Le Guin")
    #expect(authorOnly?.systemImage == "person")

    let narratorOnly = Presentation.row(.moreFrom, context: Self.bookContext(creator: nil))
    #expect(narratorOnly?.id == ItemMenuSelection.narratorLink.id)
  }

  @Test func removalInFlightIsInert() {
    let inert = Presentation.row(
      .removeDownload, context: Context(isEpisode: false, playback: Self.play, isDownloadInert: true))
    #expect(inert?.label == MediaActionCopy.removingDownload.title)
    #expect(inert?.isEnabled == false)

    let live = Presentation.row(.removeDownload, context: Context(isEpisode: false, playback: Self.play))
    #expect(live?.label == MediaActionCopy.removeDownload.title)
    #expect(live?.role == .destructive)
  }

  @Test func ebookProgressSaysContinueReading() {
    let row = Presentation.row(
      .removeFromContinueListening, context: Self.bookContext(usesEbookProgress: true))
    #expect(row?.label == "Remove from \(HomeCopy.continueReadingTitle)")
  }

  @Test func severalEreadersAreASubmenuAndASendInFlightIsInert() {
    let devices = [EbookDeliveryDevice(name: "Kindle"), EbookDeliveryDevice(name: "Kobo")]
    let row = Presentation.row(
      .sendToEreader, context: Self.bookContext(delivery: .submenu(devices), sending: ["Kobo"]))
    #expect(row?.label == EbookDeliveryCopy.submenuTitle)
    #expect(row?.children.map(\.label) == ["Kindle", "Kobo"])
    #expect(row?.children.map(\.isEnabled) == [true, false])
    #expect(row?.children.allSatisfy { $0.systemImage.isEmpty } == true)
  }

  /// The removal is the last section, and a screen's own closing action joins it.
  @Test func removalIsLastAndTheClosingActionJoinsIt() {
    let state = BookMenuPresentation.State(
      capability: .audio, isSaved: false, playbackStatus: .finished, downloadAction: .remove)
    let sections = BookMenuPresentation.actionSections(state, surface: .browse)
    let closing = MediaContextAction(
      id: ItemMenuSelection.closingAction.id, label: "Remove", hint: "", systemImage: "trash",
      role: .destructive)

    let rows = Presentation.menuSections(sections, context: Self.bookContext(), closing: closing)
    #expect(rows.last?.map(\.id) == [MediaItemAction.removeDownload.actionID, closing.id])

    let downloads = BookMenuPresentation.actionSections(state, surface: .downloads)
    let closingOnly = Presentation.menuSections(
      downloads, context: Self.bookContext(), closing: closing)
    #expect(closingOnly.last?.map(\.id) == [closing.id])
    #expect(closingOnly.count == downloads.count + 1)
  }

  /// A single progress entry is a row, not a submenu of one.
  @Test func aSingleProgressEntryIsARow() {
    let state = BookMenuPresentation.State(capability: .audio, playbackStatus: nil)
    let rows = Presentation.menuSections(
      BookMenuPresentation.actionSections(state, surface: .browse), context: Self.bookContext())
    #expect(rows.flatMap { $0 }.contains { $0.id == MediaItemMenuLayout.Submenu.progress.id } == false)
    #expect(rows.flatMap { $0 }.contains { $0.label == "Mark as Finished" })
  }

  /// A book's Watch pair keeps its own IDs and hints; an episode's draws the plain table row.
  @Test func bookWatchRowsCarryTheBookIDs() throws {
    let send = try #require(Presentation.row(.sendToWatch, context: Self.bookContext()))
    #expect(send.id == ItemMenuSelection.action(.sendToWatch).id)
    #expect(send.accessibilityIdentifier == BookWatchPresentation.send.id)
    #expect(send.hint == BookWatchPresentation.send.hint)
    #expect(send.label == MediaActionCopy.sendToWatch.title && send.isSubmenu == false)

    let remove = try #require(Presentation.row(.removeFromWatch, context: Self.bookContext()))
    #expect(remove.accessibilityIdentifier == BookWatchPresentation.remove.id)

    let episode = try #require(
      Presentation.row(.sendToWatch, context: Context(isEpisode: true, playback: Self.play)))
    #expect(episode.accessibilityIdentifier == nil)
  }

  /// A send past the Watch's last reported free space asks first, as a submenu.
  @Test func oversizedBookSendAsksInASubmenu() throws {
    var context = Self.bookContext()
    context.bookWatchOversizedMessage = "This book is 1.4 GB. Your Watch has about 600 MB free."
    let send = try #require(Presentation.row(.sendToWatch, context: context))
    #expect(send.childrenTitle == context.bookWatchOversizedMessage)
    #expect(send.children.map(\.id) == [ItemMenuSelection.sendToWatchAnyway.id])
    #expect(send.children.map(\.label) == [BookWatchPresentation.sendAnyway])
    #expect(send.accessibilityIdentifier == BookWatchPresentation.send.id)
    // Removal never asks.
    #expect(Presentation.row(.removeFromWatch, context: context)?.isSubmenu == false)
  }

  @Test func episodeSurfaceOnlyEntriesDrawNothingHere() {
    let context = Context(isEpisode: true, playback: Self.play)
    for action in [MediaItemAction.pauseDownload, .resumeDownload, .saveToServer, .removeFromServer] {
      #expect(Presentation.row(action, context: context) == nil)
    }
  }
}
