import Persistence
import Testing

@testable import AppModel

/// The book-menu counterpart of `PodcastShowPresentation.suppressedActions(on:)`. Both answer the
/// same question with the same rule (suppress what the surface presents as its own control, keep
/// what it only mentions), so the two are pinned against each other here as well as separately.
@Suite("Book menu surface")
struct BookMenuSurfaceTests {

  /// A card, a library row, a search result: the menu is the only way to reach any of this, so it
  /// withholds nothing.
  @Test("a browse surface offers every concern")
  func browseOffersEverything() {
    let entries = BookMenuSurface.browse.entries
    #expect(entries.showsPlayPause)
    #expect(entries.showsRead)
    #expect(entries.showsQueue)
    #expect(entries.showsSaved)
    #expect(entries.showsNavigation)
    #expect(entries.showsDownload)
    #expect(entries.showsProgress)
    #expect(entries.showsSendToEreader)
    #expect(entries.showsWatch)
  }

  /// Play is a full-width capsule, Save for Later and the download are the two toolbar bubbles
  /// beside the ellipsis, and the author and narrator are tappable links in the hero.
  @Test("the item detail overflow drops what the screen already presents")
  func itemDetailDropsOnScreenControls() {
    let entries = BookMenuSurface.itemDetail.entries
    #expect(entries.showsPlayPause == false)
    #expect(entries.showsRead == false)
    #expect(entries.showsSaved == false)
    #expect(entries.showsNavigation == false)
    #expect(entries.showsDownload == false)
  }

  /// Nothing else on the detail screen queues a title or moves its progress marker, so the
  /// overflow is the only place for these.
  @Test("the item detail overflow keeps the queue and progress actions")
  func itemDetailKeepsWhatHasNoOtherHome() {
    let entries = BookMenuSurface.itemDetail.entries
    #expect(entries.showsQueue)
    #expect(entries.showsProgress)
  }

  /// The Downloads screen presents deletion as its own control (a confirmed Delete swipe, and
  /// selection), so the menu drops the unconfirmed download entry and keeps everything else.
  @Test("the Downloads surface drops only the download concern")
  func downloadsDropsOnlyTheDownloadConcern() {
    let entries = BookMenuSurface.downloads.entries
    #expect(entries.showsDownload == false)
    #expect(entries.showsPlayPause)
    #expect(entries.showsRead)
    #expect(entries.showsQueue)
    #expect(entries.showsSaved)
    #expect(entries.showsNavigation)
    #expect(entries.showsProgress)
  }

  /// No screen presents sending as a control of its own, so both surfaces keep it.
  @Test("every surface offers Send to E-reader")
  func everySurfaceOffersSendToEreader() {
    for surface in BookMenuSurface.allCases {
      #expect(surface.entries.showsSendToEreader)
    }
  }

  /// The detail page has no Watch control of its own, so its overflow carries the Watch
  /// pair in the download section, which there holds nothing else.
  @Test("every surface offers the Watch pair, the detail overflow included")
  func everySurfaceOffersTheWatchPair() {
    for surface in BookMenuSurface.allCases {
      #expect(surface.entries.showsWatch)
    }
    #expect(BookMenuSurface.itemDetail.entries.showsDownload == false)
  }

  /// The guarantee that lets the ellipsis be unconditional: every playback status yields at least
  /// one progress action, so a surface keeping that concern can never present a menu with no rows.
  /// The thinnest case is an unstarted title: one row, Mark as Finished.
  @Test("keeping the progress concern is enough to keep the menu non-empty")
  func progressActionsAreNeverEmpty() {
    #expect(BookMenuSurface.itemDetail.entries.showsProgress)
    for status in [nil, ItemPlaybackStatus.inProgress, .finished] as [ItemPlaybackStatus?] {
      #expect(MediaProgressActionPolicy.actions(for: status).isEmpty == false)
    }
    #expect(MediaProgressActionPolicy.actions(for: nil) == [.markAsFinished])
  }

  /// Neither surface may withhold a concern the other never offers, which would mean the menus had
  /// stopped being one list with suppressions applied.
  @Test("every concern the detail surface keeps is one browse offers too")
  func detailIsASubsetOfBrowse() {
    let browse = BookMenuSurface.browse.entries
    let detail = BookMenuSurface.itemDetail.entries
    #expect(detail.showsPlayPause == false || browse.showsPlayPause)
    #expect(detail.showsRead == false || browse.showsRead)
    #expect(detail.showsQueue == false || browse.showsQueue)
    #expect(detail.showsSaved == false || browse.showsSaved)
    #expect(detail.showsNavigation == false || browse.showsNavigation)
    #expect(detail.showsDownload == false || browse.showsDownload)
    #expect(detail.showsProgress == false || browse.showsProgress)
    #expect(detail.showsWatch == false || browse.showsWatch)
  }

  /// The two detail surfaces reach the same answer through two vocabularies, so a change to one
  /// must be made to the other or a book's overflow and an episode's drift apart.
  @Test("a book's detail overflow suppresses what an episode's does")
  func bookAndEpisodeDetailSurfacesAgree() {
    let book = BookMenuSurface.itemDetail.entries
    let episode = PodcastShowPresentation.suppressedActions(on: .episodeDetail)

    #expect(book.showsPlayPause == (episode.contains(.playPause) == false))
    #expect(book.showsSaved == (episode.contains(.saveForLater) == false))
    #expect(book.showsDownload == (episode.contains(.download) == false))
    #expect(book.showsNavigation == (episode.contains(.openShow) == false))
    #expect(book.showsQueue == (episode.contains(.playNext) == false))
    #expect(book.showsProgress == (episode.contains(.markAsFinished) == false))
  }
}
