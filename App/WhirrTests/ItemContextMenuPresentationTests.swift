import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

/// The menu's play/pause button is a pure function of "is this the active item" and "is playback
/// intended". It is pulled out of `ItemContextMenuModifier` so the two `PlaybackModel` reads happen
/// in the menu's body, not in every row.
struct ItemContextMenuPresentationTests {
  @Test("the compact preview keeps a 220-point maximum edge")
  func compactPreviewGeometry() {
    #expect(
      ItemContextMenuPresentation.previewFrameSize(shapesToCover: false)
        == CGSize(width: 220, height: 220))
    #expect(
      ItemContextMenuPresentation.previewFrameSize(shapesToCover: true)
        == CGSize(width: CGFloat(220) * 2 / 3, height: 220))
  }

  @Test("a cached narrator produces a named snapshot")
  func cachedNarratorProducesNamedSnapshot() {
    #expect(ItemContextMenuPresentation.narratorLabel("Nina") == "Narrated by Nina")
  }

  @Test("an uncached narrator keeps a generic snapshot")
  func uncachedNarratorKeepsGenericSnapshot() {
    #expect(ItemContextMenuPresentation.narratorLabel(nil) == "Narrator")
  }

  /// The server joins every credited narrator into one field, so a two-narrator audiobook gave
  /// "Narrated by Travis Baldree, Jeff Hays", which wrapped a menu row onto a second line. System
  /// menu rows are one line, so the list collapses past the first name instead of growing.
  @Test("a multi-narrator credit collapses past the first name")
  func multipleNarratorsCollapseToACountedLabel() {
    #expect(
      ItemContextMenuPresentation.narratorLabel("Travis Baldree, Jeff Hays")
        == "Narrated by Travis Baldree & 1 more")
    #expect(
      ItemContextMenuPresentation.narratorLabel("Travis Baldree, Jeff Hays, Nina")
        == "Narrated by Travis Baldree & 2 more")
  }

  /// Whitespace and a trailing separator are the server's, not a second narrator's.
  @Test("a single narrator is never counted, however the server spaced it")
  func singleNarratorIsNeverCounted() {
    #expect(ItemContextMenuPresentation.narratorLabel("  Nina  ") == "Narrated by Nina")
    #expect(ItemContextMenuPresentation.narratorLabel("Nina,") == "Narrated by Nina")
    #expect(ItemContextMenuPresentation.narratorLabel(", ,") == "Narrator")
  }

  @Test("an item that is not playing offers Play and starts it")
  func inactiveItemOffersPlay() {
    let button = ItemContextMenuPresentation.playbackButton(
      isActiveItem: false, isPlaybackIntended: false)

    #expect(button.title == "Play")
    #expect(button.systemImage == "play.fill")
    #expect(button.action == .start)
  }

  /// The active item is what `togglePlayPause` acts on, so an active-but-paused row must toggle
  /// rather than restart, since restarting would tear down and rebuild the player for a resume.
  @Test("the active item toggles rather than restarting, even while paused")
  func activePausedItemToggles() {
    let button = ItemContextMenuPresentation.playbackButton(
      isActiveItem: true, isPlaybackIntended: false)

    #expect(button.title == "Play")
    #expect(button.systemImage == "play.fill")
    #expect(button.action == .toggle)
  }

  @Test("the active playing item offers Pause")
  func activePlayingItemOffersPause() {
    let button = ItemContextMenuPresentation.playbackButton(
      isActiveItem: true, isPlaybackIntended: true)

    #expect(button.title == "Pause")
    #expect(button.systemImage == "pause.fill")
    #expect(button.action == .toggle)
  }

  /// `isPlaybackIntended` is global to the player, not per item: another item playing must not
  /// make this row claim it is the one playing.
  @Test("playback intended elsewhere never labels an inactive row as playing")
  func inactiveItemIgnoresGlobalPlaybackIntent() {
    let button = ItemContextMenuPresentation.playbackButton(
      isActiveItem: false, isPlaybackIntended: true)

    #expect(button.title == "Play")
    #expect(button.action == .start)
  }

  /// A podcast row draws the show or episode menu, never the book one. That holds even when the
  /// server leaves a stray document format on the show, which must not route it into the book
  /// family.
  @Test("podcast rows use a podcast-specific context menu")
  func podcastRowsUsePodcastSpecificMenu() {
    #expect(ItemContextMenuAvailability.offersMenu(for: .podcast))
    #expect(ItemMediaCapability.derive(category: .podcast, hasReadableEbook: false) == .podcast)
    #expect(ItemMediaCapability.derive(category: .podcast, hasReadableEbook: true) == .podcast)
  }

  @Test("audiobook and ebook rows keep the item-level context menu")
  func nonPodcastRowsKeepTheMenu() {
    #expect(ItemContextMenuAvailability.offersMenu(for: .audiobook))
    #expect(ItemContextMenuAvailability.offersMenu(for: .ebook))
  }

  /// The two capability flags `BookMenuPresentation` reads, for every book-family shape it can be
  /// handed. Ebooks must not offer Play (no audio), and a PDF sidecar must not offer Read (it could
  /// only fail), so a wrong answer here is a wrong menu on a device.
  @Test("the book menu offers Play and Read strictly by media capability")
  func bookMenuBranchDecisionTable() {
    let cases:
      [(
        category: ItemMediaCategory,
        hasReadableEbook: Bool,
        offersPlay: Bool,
        offersRead: Bool
      )] = [
        (.audiobook, false, true, false),
        (.audiobook, true, true, true),
        (.ebook, true, false, true),
        (.ebook, false, false, false),
      ]

    for entry in cases {
      let capability = ItemMediaCapability.derive(
        category: entry.category, hasReadableEbook: entry.hasReadableEbook)
      #expect(capability.supportsPlayback == entry.offersPlay, "play for \(capability)")
      #expect(capability.supportsReading == entry.offersRead, "read for \(capability)")
    }
  }

  /// The details-only branch: nothing this menu can offer for an unopenable document would work,
  /// so it draws View Details and the creator link and stops.
  @Test("an unsupported standalone document gets a details-only menu")
  func unsupportedDocumentGetsDetailsOnlyMenu() {
    let capability = ItemMediaCapability.derive(category: .ebook, hasReadableEbook: false)

    #expect(capability == .unsupportedDocument)
    #expect(capability.supportsPlayback == false)
    #expect(capability.supportsReading == false)
    #expect(capability.supportsDownload == false)
  }

  /// A mixed audiobook and EPUB draws a submenu; every single-format item keeps one Download row.
  /// The menu branches on this count, so a wrong answer is a wrong menu on a device. Mixed items
  /// must offer the choice rather than silently fetch audio only.
  @Test("only a mixed item's Download row becomes a submenu")
  func mixedItemDownloadRowBecomesASubmenu() {
    let mixed = ItemMediaCapability.derive(category: .audiobook, hasReadableEbook: true)
    #expect(mixed.downloadFormats == [.audio, .ebook, .both])

    for capability in [ItemMediaCapability.audio, .ebook, .podcast] {
      #expect(capability.downloadFormats.count == 1, "single Download row for \(capability)")
    }
  }

  /// Titles come from `ItemDownloadCopy`, which the detail screen's bubble menu also reads, so the
  /// two surfaces name each choice the same way. Glyphs are the media badges' own, and `.both`
  /// keeps the plain download glyph.
  @Test("download format entries reuse the shared copy and the media badge glyphs")
  func downloadFormatEntriesReuseSharedCopyAndGlyphs() {
    let audio = ItemContextMenuPresentation.downloadFormatEntry(.audio)
    #expect(audio.title == "Download Audiobook")
    #expect(audio.systemImage == MediaKindBadge.audiobook.symbolName)

    let ebook = ItemContextMenuPresentation.downloadFormatEntry(.ebook)
    #expect(ebook.title == "Download eBook")
    #expect(ebook.systemImage == MediaKindBadge.ebook.symbolName)

    let both = ItemContextMenuPresentation.downloadFormatEntry(.both)
    #expect(both.title == "Download Both")
    #expect(both.systemImage == ItemContextMenuPresentation.downloadEntry.systemImage)
  }

  @Test("saved entries carry state in both their copy and glyph")
  func savedEntryCopyAndGlyphFollowMembership() {
    let unsaved = ItemContextMenuPresentation.savedEntry(isSaved: false)
    #expect(unsaved.title == "Save for Later")
    #expect(unsaved.systemImage == "bookmark")

    let saved = ItemContextMenuPresentation.savedEntry(isSaved: true)
    #expect(saved.title == "Remove from Saved")
    #expect(saved.systemImage == "bookmark.fill")
  }

  @Test("book creator links retain named copy")
  func bookCreatorLinksRetainNamedCopy() {
    #expect(
      ItemContextMenuPresentation.creatorLabel(category: .audiobook, creator: "Octavia Butler")
        == "Books by Octavia Butler")
    #expect(ItemContextMenuPresentation.creatorLabel(category: .podcast, creator: "  ") == nil)
  }

}
