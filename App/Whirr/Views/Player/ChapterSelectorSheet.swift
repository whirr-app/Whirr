import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI

struct ChapterSelectorSheet: View {
  enum Mode: Hashable {
    case chapters
    case bookmarks
  }

  let chapters: [PlaybackChapter]
  let currentTime: Double
  let isFinished: Bool
  /// The item's Audiobookshelf bookmarks; `nil` (an episode, a device-owned item) leaves the sheet
  /// as a chapter list with no switch.
  var bookmarksModel: AudioBookmarksModel? = nil
  var onSelectBookmark: (AudioBookmark) -> Void = { _ in }
  /// Queues one chapter in Up Next; nil where the playing title's chapters cannot be queued.
  var onQueueChapter: ((ChapterQueueAction, ListeningQueueChapter) -> Void)? = nil
  /// Appends Select mode's chapters to Up Next in the order chosen; nil offers no Select mode.
  var onQueueChapters: (([ListeningQueueChapter]) -> Void)? = nil
  let onSelect: (PlaybackChapter) -> Void

  @State private var section: Mode = .chapters
  /// Non-nil while Select mode is on.
  @State private var selection: ChapterSelection?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // In the body, as the item page's Chapters | Contents switch is: a principal toolbar item
        // sits on the bar's glass and loses the control's own glass selection thumb.
        if bookmarksModel != nil {
          Picker("Show", selection: $section) {
            Text("Chapters").tag(Mode.chapters)
            Text("Bookmarks").tag(Mode.bookmarks)
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, WhirrSpacing.medium)
          .padding(.vertical, WhirrSpacing.small)
        }

        content
          .frame(maxHeight: .infinity)
      }
      .navigationTitle(section == .bookmarks ? "Bookmarks" : "Chapters")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) {
            dismiss()
          }
        }
        if offersSelectMode {
          ToolbarItem(placement: .topBarTrailing) {
            ChapterSelectModeButton(selection: $selection)
          }
        }
      }
      // Select mode belongs to the chapter list; another tab leaves it.
      .onChange(of: section) { selection = nil }
    }
  }

  private var offersSelectMode: Bool {
    onQueueChapters != nil && section == .chapters && chapters.isEmpty == false
  }

  @ViewBuilder
  private var content: some View {
    if let bookmarksModel, section == .bookmarks {
      PlayerBookmarksList(model: bookmarksModel, chapters: chapters) { bookmark in
        onSelectBookmark(bookmark)
        dismiss()
      }
    } else {
      ChapterSelectorList(
        chapters: chapters, currentTime: currentTime, isFinished: isFinished,
        onQueueAction: onQueueChapter.map { onQueueChapter in
          { row, action in
            onQueueChapter(action, ChapterQueueAction.queueChapter(row.chapter, displayTitle: row.title))
          }
        },
        selection: $selection,
        onQueueSelection: onQueueChapters.map { onQueueChapters in
          { rows in
            onQueueChapters(
              rows.map { ChapterQueueAction.queueChapter($0.chapter, displayTitle: $0.title) })
            selection = nil
          }
        }
      ) { chapter in
        onSelect(chapter)
        dismiss()
      }
    }
  }
}

/// The chapter list both chapter sheets show (the player's and the item-detail page's). It
/// supplies its own scrolling, so a host places it directly inside a `NavigationStack` and owns
/// only the title, close button, and dismissal order.
struct ChapterSelectorList: View {
  let chapters: [PlaybackChapter]
  let currentTime: Double?
  var isFinished = false
  /// Up Next actions for a chapter row's context menu. Nil where the title's chapters cannot be
  /// queued.
  var onQueueAction: ((ChapterSelectorRow, ChapterQueueAction) -> Void)?
  /// Select mode, owned by the host's toolbar: non-nil while on. A row tap then chooses the
  /// chapter instead of seeking to it.
  var selection: Binding<ChapterSelection?> = .constant(nil)
  /// Queues the chosen rows in the order chosen.
  var onQueueSelection: (([ChapterSelectorRow]) -> Void)? = nil
  let onSelect: (PlaybackChapter) -> Void

  private var rows: [ChapterSelectorRow] {
    ChapterSelectorPresentation.rows(
      chapters: chapters, currentTime: currentTime, isFinished: isFinished)
  }

  var body: some View {
    ScrollViewReader { proxy in
      List {
        ForEach(rows) { row in
          chapterRow(row)
            .id(row.id)
        }
      }
      .listStyle(.plain)
      .overlay {
        if chapters.isEmpty {
          ContentUnavailableView(
            "No Chapters",
            systemImage: "list.bullet.rectangle",
            description: Text("This title does not include chapter markers.")
          )
        }
      }
      .onAppear {
        guard let currentRow = rows.first(where: \.isCurrent) else { return }
        proxy.scrollTo(currentRow.id, anchor: .center)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let chosen = selection.wrappedValue, let onQueueSelection {
          Button {
            onQueueSelection(chosen.rows(in: rows))
          } label: {
            Text(ChapterSelection.addLabel(count: chosen.count))
              .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
          }
          // Tint and label are stated, not inherited: the expanded player's tint is near-white in
          // dark appearance, and a prominent style left to itself paints a white label on it.
          .tint(AppChrome.tint)
          .foregroundStyle(AppChrome.onTint)
          .buttonStyle(.glassProminent)
          .buttonBorderShape(.capsule)
          .disabled(chosen.count == 0)
          .padding(.horizontal, WhirrSpacing.medium)
          .padding(.vertical, WhirrSpacing.small)
          // Rows scroll under the button; the bar keeps their text from showing through it.
          .background(.bar)
          .accessibilityIdentifier(PlayerAccessibilityID.chapterQueueSelection)
        }
      }
    }
  }

  @ViewBuilder
  private func chapterRow(_ row: ChapterSelectorRow) -> some View {
    if let chosen = selection.wrappedValue {
      selectableRow(row, number: chosen.number(of: row.id))
    } else {
      playableRow(row)
    }
  }

  /// Select mode's row: a tap chooses it or lets it go, and its number says where it will queue.
  private func selectableRow(_ row: ChapterSelectorRow, number: Int?) -> some View {
    ChapterRow(
      title: row.title,
      timingText: "\(row.startLabel) · \(row.durationLabel)",
      isCurrent: row.isCurrent,
      isCompleted: row.isCompleted,
      trailingIndicatorSystemImage: ChapterSelection.indicatorSymbol(number: number),
      accessibilityLabel: row.accessibilityLabel,
      accessibilityValue:
        "\(row.startLabel), \(row.durationLabel), "
        + ChapterSelection.accessibilityValue(number: number),
      onSelect: { selection.wrappedValue?.toggle(row.id) }
    )
    .accessibilityAddTraits(number == nil ? [] : .isSelected)
  }

  private func playableRow(_ row: ChapterSelectorRow) -> some View {
    ChapterRow(
      title: row.title,
      timingText: "\(row.startLabel) · \(row.durationLabel)",
      isCurrent: row.isCurrent,
      isCompleted: row.isCompleted,
      trailingIndicatorSystemImage: row.isCurrent
        ? "waveform"
        : row.isCompleted ? "checkmark.circle.fill" : nil,
      accessibilityLabel: row.accessibilityLabel,
      accessibilityValue:
        "\(row.startLabel), \(row.durationLabel)"
        + (row.isCurrent ? ", currently playing" : row.isCompleted ? ", completed" : ""),
      onSelect: { onSelect(row.chapter) }
    )
    .contextMenu {
      if let onQueueAction {
        ForEach(ChapterQueueAction.allCases) { action in
          Button {
            onQueueAction(row, action)
          } label: {
            Label(action.label, systemImage: action.systemImage)
          }
        }
      }
    }
  }
}

/// The chapter sheets' toolbar switch into and out of Select mode.
struct ChapterSelectModeButton: View {
  @Binding var selection: ChapterSelection?

  var body: some View {
    Button(selection == nil ? ChapterSelection.selectLabel : ChapterSelection.cancelLabel) {
      selection = selection == nil ? ChapterSelection() : nil
    }
    .accessibilityHint(selection == nil ? ChapterSelection.selectHint : "")
    .accessibilityIdentifier(PlayerAccessibilityID.chapterSelectMode)
  }
}
