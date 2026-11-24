import AppModel
import DesignSystem
import ReaderCore
import SwiftUI

/// The ebook Contents tab. ABS chapters are audio markers, so an ebook has none; the list is the
/// EPUB's navigation document, read from the download by `ItemContentsModel` and stored beside the
/// item, so it survives removing the download. Entries carry their position so rows mark read as
/// Chapters does. Every non-loaded state says what it is, not an empty list.
struct ItemDetailContentsSection: View {
  let contentsModel: ItemContentsModel?
  let isFinished: Bool
  let onSelectEntry: (ItemContentsRow) -> Void

  var body: some View {
    switch contentsModel?.state {
    case nil, .some(.unavailable):
      EmptyStateView(
        title: "Contents Unavailable",
        message: "This book's contents couldn't be read.",
        systemImage: "list.bullet.indent"
      )
    case .some(.needsDownload):
      EmptyStateView(
        title: "Not Downloaded",
        message: "Download this book to see its contents.",
        systemImage: "arrow.down.circle"
      )
    case .some(.downloading):
      LoadingStateView(message: "Downloading…")
    case .some(.loading):
      LoadingStateView(message: "Reading contents…")
    case .some(.loaded(let entries)):
      if entries.isEmpty {
        EmptyStateView(
          title: "No Contents",
          message: "This book includes no table of contents.",
          systemImage: "list.bullet.indent"
        )
      } else {
        entryList(entries)
      }
    }
  }

  private func entryList(_ entries: [TOCEntry]) -> some View {
    let rows = ItemContentsPresentation.rows(
      entries: entries,
      progress: contentsModel?.ebookProgress,
      isFinished: isFinished)

    return LazyVStack(spacing: 0) {
      ForEach(rows) { row in
        entryRow(row)
        if row.id != rows.count - 1 {
          Divider()
        }
      }
    }
    .accessibilityIdentifier(ItemDetailContentsAccessibilityID.list)
  }

  private func entryRow(_ row: ItemContentsRow) -> some View {
    Button {
      onSelectEntry(row)
    } label: {
      HStack(spacing: WhirrSpacing.small) {
        Text(row.entry.title)
          .font(.body)
          .fontWeight(row.isCurrent ? .semibold : .regular)
          .foregroundStyle(Self.titleColorToken(for: row).color)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        // Read state is never glyph-only: the title's weight and colour carry it too, matching
        // `ChapterRow`'s treatment of the same two states.
        if let indicator = Self.indicatorSystemImage(for: row) {
          Image(systemName: indicator)
            .foregroundStyle(
              row.isCurrent
                ? AnyShapeStyle(.tint) : AnyShapeStyle(WhirrColorToken.textSecondary.color))
        }
      }
      // Nesting depth is the only thing distinguishing a part heading from the chapters under it.
      .padding(.leading, CGFloat(row.entry.depth) * WhirrSpacing.medium)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(Self.accessibilityValue(for: row))
    .accessibilityHint(Self.accessibilityHint(for: row))
  }

  /// Completed entries stay readable as completed through this secondary treatment as well as the
  /// trailing glyph, matching `ChapterRow.titleColorToken`.
  static func titleColorToken(for row: ItemContentsRow) -> WhirrColorToken {
    row.isCompleted ? .textSecondary : .textPrimary
  }

  /// The reading twin of the Chapters tab's waveform/checkmark pair. The current entry gets the
  /// same bookmark as the reader's own contents sheet (`ReaderView.tocSheet`).
  static func indicatorSystemImage(for row: ItemContentsRow) -> String? {
    if row.isCurrent { return "bookmark.fill" }
    return row.isCompleted ? "checkmark.circle.fill" : nil
  }

  static func accessibilityValue(for row: ItemContentsRow) -> String {
    if row.isCurrent { return "Currently reading" }
    return row.isCompleted ? "Read" : ""
  }

  /// The current entry is a resume, not a jump: tapping it lands on the page reading stopped at,
  /// not the entry's head.
  static func accessibilityHint(for row: ItemContentsRow) -> String {
    row.isCurrent ? "Opens the reader where you left off." : "Opens the reader at this entry."
  }
}

enum ItemDetailContentsAccessibilityID {
  static let list = "item-detail-contents-list"
}
