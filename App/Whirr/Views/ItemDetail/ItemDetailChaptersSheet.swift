import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

/// The item-detail jump list. Audio chapters, bookmarks and ebook contents share one sheet because
/// each is a way to choose a place in the same title; the picker keeps those lists distinct without
/// putting a second navigation destination in the detail page. An audiobook's Chapters | Bookmarks
/// pair is the player's chapter sheet's.
struct ItemDetailChaptersSheet: View {
  private typealias Tab = ItemDetailJumpListPresentation.Tab

  let item: ItemSummary
  let extrasModel: ItemDetailExtrasModel
  let playback: PlaybackModel
  let contentsModel: ItemContentsModel
  let isFinished: Bool
  /// Nil in the detail harness, which has no item-action model; chapters are then not queueable.
  let actions: ItemActionsModel?
  /// Builds the item's bookmarks model; nil in the detail harness, which then offers no bookmarks.
  let makeBookmarksModel: ((String) -> AudioBookmarksModel)?
  let onSelectChapter: (PlaybackChapter) -> Void
  let onSelectBookmark: (AudioBookmark) -> Void
  let onPresentReaderAtEntry: (String, String, ItemMediaCategory, ReaderRestoreTarget?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selectedList: Tab
  /// Non-nil while the chapter list's Select mode is on.
  @State private var chapterSelection: ChapterSelection?
  /// Built on first read and kept for the sheet's life, so a body re-run does not restart the
  /// model's bookmark observation.
  @State private var bookmarks = DeferredModel<AudioBookmarksModel?>()

  private let capability: ItemMediaCapability
  private let tabs: [Tab]

  init(
    item: ItemSummary,
    extrasModel: ItemDetailExtrasModel,
    playback: PlaybackModel,
    contentsModel: ItemContentsModel,
    isFinished: Bool,
    actions: ItemActionsModel? = nil,
    makeBookmarksModel: ((String) -> AudioBookmarksModel)? = nil,
    onSelectChapter: @escaping (PlaybackChapter) -> Void,
    onSelectBookmark: @escaping (AudioBookmark) -> Void = { _ in },
    onPresentReaderAtEntry:
      @escaping (String, String, ItemMediaCategory, ReaderRestoreTarget?) -> Void
  ) {
    self.item = item
    self.extrasModel = extrasModel
    self.playback = playback
    self.contentsModel = contentsModel
    self.isFinished = isFinished
    self.actions = actions
    self.makeBookmarksModel = makeBookmarksModel
    self.onSelectChapter = onSelectChapter
    self.onSelectBookmark = onSelectBookmark
    self.onPresentReaderAtEntry = onPresentReaderAtEntry
    let capability = ItemMediaCapability.derive(
      category: item.category, hasReadableEbook: item.hasReadableEbook)
    self.capability = capability
    let tabs = ItemDetailJumpListPresentation.tabs(
      capability: capability, itemID: item.serverItemId
    )
    .filter { $0 != .bookmarks || makeBookmarksModel != nil }
    self.tabs = tabs
    _selectedList = State(initialValue: tabs.first ?? .chapters)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if tabs.count > 1 {
          Picker("Show", selection: $selectedList) {
            ForEach(tabs, id: \.self) { tab in
              Text(tab.title).tag(tab)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, WhirrSpacing.medium)
          .padding(.vertical, WhirrSpacing.small)
        }

        listContent
          .frame(maxHeight: .infinity)
      }
      .navigationTitle(selectedList.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) {
            dismiss()
          }
        }
        if selectedList == .chapters, queueChapters != nil {
          ToolbarItem(placement: .topBarTrailing) {
            ChapterSelectModeButton(selection: $chapterSelection)
          }
        }
      }
      // Select mode belongs to the chapter list; another tab leaves it.
      .onChange(of: selectedList) { chapterSelection = nil }
    }
    // The detail page's own banner sits under this sheet, so the confirmation is shown here too.
    .queueFeedbackBanner(
      message: actions?.queueFeedbackMessage, onDismiss: { actions?.dismissQueueFeedback() })
  }

  private var queueChapter: ((ChapterQueueAction, ListeningQueueChapter) -> Void)? {
    guard let actions, ChapterQueueAction.isOffered(for: capability) else { return nil }
    let itemID = item.serverItemId
    return { action, chapter in
      Task {
        switch action {
        case .playNext: await actions.playNext(itemID: itemID, chapter: chapter)
        case .addToUpNext: await actions.addToUpNext(itemID: itemID, chapter: chapter)
        }
      }
    }
  }

  private var queueChapters: (([ListeningQueueChapter]) -> Void)? {
    guard let actions, ChapterQueueAction.isOffered(for: capability) else { return nil }
    let itemID = item.serverItemId
    return { chapters in
      chapterSelection = nil
      Task { await actions.addToUpNext(itemID: itemID, chapters: chapters) }
    }
  }

  private var bookmarksModel: AudioBookmarksModel? {
    bookmarks.resolve { [makeBookmarksModel, item] in makeBookmarksModel?(item.serverItemId) }
  }

  @ViewBuilder
  private var listContent: some View {
    if tabs.isEmpty {
      ContentUnavailableView(
        "Jump List Unavailable",
        systemImage: "book.closed",
        description: Text("This title has no audio chapters or readable ebook contents.")
      )
    } else {
      switch selectedList {
      case .chapters:
        chaptersSection
      case .bookmarks:
        if let bookmarksModel {
          PlayerBookmarksList(
            model: bookmarksModel, chapters: loadedChapters, onSelect: selectBookmark)
        }
      case .contents:
        contentsSection
      }
    }
  }

  /// The chapters a bookmark row names its place by; none until the item's extras load.
  private var loadedChapters: [PlaybackChapter] {
    guard case .loaded(let extras) = extrasModel.state else { return [] }
    return extras.chapters.map { PlaybackChapter(title: $0.title, start: $0.start, end: $0.end) }
  }

  private var chaptersSection: some View {
    ItemDetailChaptersSection(
      itemID: item.serverItemId,
      extrasModel: extrasModel,
      playback: playback,
      isFinished: isFinished,
      persistedPositionSeconds: item.progressSeconds,
      onQueueChapter: queueChapter,
      selection: $chapterSelection,
      onQueueChapters: queueChapters,
      onSelectChapter: selectChapter
    )
  }

  private var contentsSection: some View {
    // The contents section is a plain stack; the chapter list supplies its own scrolling.
    ScrollView {
      ItemDetailContentsSection(
        contentsModel: contentsModel,
        isFinished: isFinished,
        onSelectEntry: selectEntry
      )
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.small)
    }
  }

  private func selectChapter(_ chapter: PlaybackChapter) {
    // Dismiss first: forwarding a selection while this sheet is live can present the reader or
    // seek from beneath it, leaving the new destination covered by the old presentation.
    dismiss()
    onSelectChapter(chapter)
  }

  private func selectBookmark(_ bookmark: AudioBookmark) {
    // Dismiss first, as for a chapter.
    dismiss()
    onSelectBookmark(bookmark)
  }

  private func selectEntry(_ row: ItemContentsRow) {
    // Dismiss first: forwarding a selection while this sheet is live can present the reader or
    // seek from beneath it, leaving the new destination covered by the old presentation.
    dismiss()
    onPresentReaderAtEntry(
      item.serverItemId,
      item.title,
      item.category,
      ItemContentsNavigation.target(for: row))
  }
}
