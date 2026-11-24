import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Which item surfaces are offered the shared long-press menu.
nonisolated enum ItemContextMenuAvailability {
  static func offersMenu(for category: ItemMediaCategory) -> Bool {
    switch category {
    case .audiobook, .podcast, .ebook: true
    }
  }
}

/// The shared native long-press menu for every item surface. SwiftUI owns the presentation,
/// preview lift, Liquid Glass material, separators, and destructive styling.
///
/// `.contextMenu(menuItems:preview:)` takes non-escaping closures that run at row-body time, once
/// per row, on the scroll path. Both return a single child view
/// (`ItemContextMenuContent`/`ItemContextMenuPreview`) that reads no observable state until the
/// menu is presented. Reading playback state inline would make every visible row and Home card
/// observe `playback.activeItemID`/`isPlaybackIntended`, so one play/pause tap would invalidate
/// the list.
private struct ItemContextMenuModifier: ViewModifier {
  let subject: ItemMenuSubject
  let placement: PodcastMenuBearingSurface
  let bookSurface: BookMenuSurface
  let closingAction: ItemMenuClosingAction?
  let onOpen: () -> Void
  let onRead: (() -> Void)?
  let onSearch: (String) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    #if DEBUG || PERF_INVESTIGATION
      if HarnessAblation.noContextMenus {
        content
      } else {
        contextMenu(content: content)
      }
    #else
      contextMenu(content: content)
    #endif
  }

  private func contextMenu(content: Content) -> some View {
    content.contextMenu {
      ItemContextMenuContent(
        itemID: subject.itemID,
        author: subject.author,
        duration: subject.duration,
        category: subject.category,
        hasReadableEbook: subject.hasReadableEbook,
        usesEbookProgress: subject.usesEbookProgress,
        episodeID: subject.episodeID,
        playbackStatus: subject.playbackStatus,
        showsNarratorLink: subject.showsNarratorLink,
        narratorLabel: ItemContextMenuPresentation.narratorLabel(subject.narrator),
        playback: subject.playback,
        actions: subject.actions,
        placement: placement,
        bookSurface: bookSurface,
        closingAction: closingAction,
        onOpen: onOpen,
        onRead: onRead,
        onSearch: onSearch)
    } preview: {
      ItemContextMenuPreview(
        itemID: subject.itemID, title: subject.title, author: subject.author,
        loadsExtras: subject.category == .audiobook,
        coverClient: subject.coverClient, source: subject.source, revision: subject.revision,
        actions: subject.actions,
        // An ebook cover is portrait, so the lifted card takes the cover's shape and hugs it with
        // no margins; the slim card is itself the "this is a book" cue. Audiobook and podcast
        // covers are square and keep the square card. Computed from `category` alone, so the
        // preview closure reads no observable state.
        shapesToCover: subject.category == .ebook)
    }
  }
}
extension View {
  /// `subject` carries the item's own menu facts, including `category`, so the menu's
  /// media-specific contents are selected in one place and item surfaces cannot accidentally offer
  /// whole-book actions for a podcast show or episode.
  ///
  /// `placement` is required and names the UI raising the menu; its suppression context derives
  /// from the inventory (`PodcastMenuBearingSurface.menuSurface`), never from the caller.
  @ViewBuilder
  func itemContextMenu(
    _ subject: ItemMenuSubject,
    placement: PodcastMenuBearingSurface,
    bookSurface: BookMenuSurface = .browse,
    closingAction: ItemMenuClosingAction? = nil,
    onOpen: @escaping () -> Void,
    onRead: (() -> Void)? = nil,
    onSearch: @escaping (String) -> Void
  ) -> some View {
    if subject.offersMenu {
      modifier(
        ItemContextMenuModifier(
          subject: subject,
          placement: placement,
          bookSurface: bookSurface,
          closingAction: closingAction,
          onOpen: onOpen,
          onRead: onRead,
          onSearch: onSearch))
    } else {
      self
    }
  }
}

/// A screen's own action, appended to the shared menu as the twin of a swipe that screen owns.
///
/// Example: the Downloads screen's confirmed Delete replaces the menu's download entry, which
/// removes without asking (`BookMenuSurface.downloads`). Closures and values only, so building one
/// at row-body time reads no observable state.
struct ItemMenuClosingAction {
  let title: String
  let systemImage: String
  let isDisabled: Bool
  let action: () -> Void
}
