import AppModel
import Persistence
import Testing

@Suite struct BookMenuPresentationTests {
  private typealias State = BookMenuPresentation.State

  private static let bookCapabilities: [ItemMediaCapability] = [
    .audio, .ebook, .audioAndEbook, .unsupportedDocument,
  ]
  private static let downloadActions: [ItemContextMenuDownloadAction] = [
    .download, .remove, .unavailable,
  ]
  private static let playbackStatuses: [ItemPlaybackStatus?] = [nil, .inProgress, .finished]

  /// Every combination of the inputs that change which rows a book draws.
  private static var everyState: [State] {
    var states: [State] = []
    for capability in bookCapabilities {
      for downloadAction in downloadActions {
        for playbackStatus in playbackStatuses {
          for isSaved in [nil, false, true] as [Bool?] {
            states.append(
              State(
                capability: capability, isSaved: isSaved, queueAvailability: .both,
                playbackStatus: playbackStatus, downloadAction: downloadAction,
                canSendToEreader: true))
          }
        }
      }
    }
    return states
  }

  private static func actions(_ state: State, on surface: BookMenuSurface) -> [MediaItemAction] {
    BookMenuPresentation.actionSections(state, surface: surface).flatMap(\.actions)
  }

  @Test func bookMenuIsIdenticalAcrossSurfacesExceptSuppressedEntries() {
    for state in Self.everyState {
      let canonical = Self.actions(state, on: .browse)
      for surface in BookMenuSurface.allCases {
        let suppressed = surface.suppressedActions
        #expect(
          Self.actions(state, on: surface) == canonical.filter { suppressed.contains($0) == false },
          "\(surface) differs from browse by something other than its suppressions for \(state)")
      }
    }
  }

  @Test func browseDrawsEverySectionInTheSharedOrder() {
    let state = State(
      capability: .audioAndEbook, isSaved: false, queueAvailability: .both,
      playbackStatus: .inProgress, canSendToEreader: true)
    let sections = BookMenuPresentation.actionSections(state, surface: .browse)

    #expect(sections.map(\.kind) == MediaItemMenuSection.allCases.filter { $0 != .destructive })
    #expect(
      sections.map(\.actions) == [
        [.playPause, .playNext, .addToUpNext, .read],
        [.saveForLater],
        [.moreFrom],
        [.download],
        [.markAsFinished, .resetProgress, .removeFromContinueListening],
        [.sendToEreader],
      ])
  }

  /// Ebooks must not offer Play (no audio), and an audiobook must not offer Read.
  @Test func playAndReadFollowCapability() {
    let audio = Self.actions(State(capability: .audio, queueAvailability: .both), on: .browse)
    let ebook = Self.actions(State(capability: .ebook, queueAvailability: .both), on: .browse)

    #expect(audio.contains(.playPause) && audio.contains(.read) == false)
    #expect(ebook.contains(.read) && ebook.contains(.playPause) == false)
    #expect(ebook.contains(.playNext) == false)
  }

  /// The podcast screens cannot open the reader, so they leave Read out rather than draw it inert.
  @Test func readNeedsAReader() {
    let state = State(capability: .ebook, canOpenReader: false)
    #expect(Self.actions(state, on: .browse).contains(.read) == false)
  }

  @Test func unsupportedDocumentOffersDetailsCreatorAndSendOnly() {
    let state = State(
      capability: .unsupportedDocument, isSaved: false, queueAvailability: .both,
      playbackStatus: .inProgress, canSendToEreader: true)
    let sections = BookMenuPresentation.actionSections(state, surface: .browse)

    #expect(sections.map(\.actions) == [[.viewDetails], [.moreFrom], [.sendToEreader]])
    #expect(sections.map(\.kind) == [.primary, .navigation, .server])
  }

  @Test func absentInputsDrawNoEmptySection() {
    let state = State(
      capability: .audio, isSaved: nil, queueAvailability: .none,
      hasCreatorOrNarratorLink: false, canSendToEreader: false)
    let sections = BookMenuPresentation.actionSections(state, surface: .browse)

    #expect(sections.map(\.kind) == [.primary, .download, .progress])
    #expect(sections.allSatisfy { $0.actions.isEmpty == false })
  }

  /// A purge in flight keeps the removal row, drawn inert, so it does not vanish mid-purge.
  @Test func removalInFlightKeepsTheRemoveEntry() {
    for downloadAction in [ItemContextMenuDownloadAction.remove, .unavailable] {
      let state = State(capability: .audio, downloadAction: downloadAction)
      let sections = BookMenuPresentation.actionSections(state, surface: .browse)
      #expect(sections.last?.kind == .destructive)
      #expect(sections.last?.actions == [.removeDownload])
      #expect(sections.contains { $0.kind == .download } == false)
    }
  }

  /// Whatever destroys something is the last section, for a book and an episode alike.
  @Test func removalIsAlwaysTheLastSection() {
    for state in Self.everyState {
      let sections = BookMenuPresentation.actionSections(state, surface: .browse)
      for (index, section) in sections.enumerated() where section.actions.contains(.removeDownload) {
        #expect(section.kind == .destructive && index == sections.count - 1, "\(state)")
      }
    }
    let episode = PodcastShowPresentation.episodeActionSections(
      status: .completed, isAvailableOnServer: true, surface: .show, isSaved: false,
      playbackStatus: .inProgress, serverSave: .enabled, serverRemove: .enabled)
    #expect(episode.last?.kind == .destructive)
    #expect(episode.last?.actions == [.removeDownload, .removeFromServer])
    #expect(episode.first { $0.kind == .server }?.actions == [.saveToServer])
  }

  @Test func itemDetailKeepsOnlyWhatItsScreenDoesNotShow() {
    let state = State(
      capability: .audioAndEbook, isSaved: false, queueAvailability: .both,
      playbackStatus: .inProgress, canSendToEreader: true)
    #expect(
      Self.actions(state, on: .itemDetail) == [
        .playNext, .addToUpNext, .markAsFinished, .resetProgress, .removeFromContinueListening,
        .sendToEreader,
      ])
  }

  /// The Watch pair follows the device download, as an episode's does, and only a book
  /// with audio gets it. Item detail draws no download row but keeps the pair.
  @Test func watchPairFollowsTheDeviceDownload() {
    let send = State(capability: .audio, downloadAction: .download, watchCopy: .notOnWatch)
    #expect(
      BookMenuPresentation.actionSections(send, surface: .browse)
        .first { $0.kind == .download }?.actions == [.download, .sendToWatch])
    #expect(
      BookMenuPresentation.actionSections(send, surface: .itemDetail)
        .first { $0.kind == .download }?.actions == [.sendToWatch])

    let remove = State(capability: .audio, downloadAction: .remove, watchCopy: .onWatch)
    let sections = BookMenuPresentation.actionSections(remove, surface: .browse)
    #expect(sections.first { $0.kind == .download }?.actions == [.removeFromWatch])
    #expect(sections.last?.actions == [.removeDownload])

    for capability in [ItemMediaCapability.ebook, .unsupportedDocument] {
      let state = State(capability: capability, watchCopy: .notOnWatch)
      #expect(Self.actions(state, on: .browse).contains(.sendToWatch) == false, "\(capability)")
    }
  }

  /// For the same state, a book and an episode put every action they share in the same section and
  /// the same relative order, so the two families cannot drift apart again.
  @Test func booksAndEpisodesPlaceSharedActionsAlike() {
    let downloads: [(ItemContextMenuDownloadAction, ItemDownloadStatus)] = [
      (.download, .notDownloaded), (.remove, .completed),
    ]
    for (bookDownload, episodeStatus) in downloads {
      for playbackStatus in Self.playbackStatuses {
        for isSaved in [false, true] {
          let book = BookMenuPresentation.actionSections(
            State(
              capability: .audio, isSaved: isSaved, queueAvailability: .both,
              playbackStatus: playbackStatus, downloadAction: bookDownload),
            surface: .browse)
          let episode = PodcastShowPresentation.episodeActionSections(
            status: episodeStatus, isAvailableOnServer: true, surface: .episodeList,
            isSaved: isSaved, playbackStatus: playbackStatus)

          let bookPlacement = Self.placement(book)
          let episodePlacement = Self.placement(episode)
          let shared = bookPlacement.map(\.action).filter { action in
            episodePlacement.contains { $0.action == action }
          }
          #expect(shared.isEmpty == false)
          #expect(
            bookPlacement.filter { shared.contains($0.action) }
              == episodePlacement.filter { shared.contains($0.action) },
            "\(bookDownload), \(String(describing: playbackStatus)), saved \(isSaved)")
        }
      }
    }
  }

  private struct Placement: Equatable {
    let action: MediaItemAction
    let section: MediaItemMenuSection
  }

  private static func placement(_ sections: [MediaItemActionSection]) -> [Placement] {
    sections.flatMap { section in
      section.actions.map { Placement(action: $0, section: section.kind) }
    }
  }

  /// A menu row carries `actionID` and the menu dispatches through `init?(actionID:)`.
  @Test func everyActionIDRoundTrips() {
    for action in MediaItemAction.allCases {
      #expect(MediaItemAction(actionID: action.actionID) == action)
    }
    #expect(Set(MediaItemAction.allCases.map(\.actionID)).count == MediaItemAction.allCases.count)
    #expect(MediaItemAction(actionID: "send-to-ereader") == .sendToEreader)
  }
}
