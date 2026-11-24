import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI

/// The expanded player's bookmark state: the item's model, the add confirmation, and the rename
/// that confirmation can lead to. One object so the page holds one property for all of it.
@MainActor
@Observable
final class PlayerBookmarkController {
  private(set) var model: AudioBookmarksModel?
  private(set) var confirmation: PlayerBookmarkPresentation.Confirmation?
  /// Bumped per confirmation, so a second identical one restarts the banner's window.
  private(set) var confirmationGeneration = 0
  /// The bookmark the page's rename alert is editing, raised from the banner's Edit action.
  var renameTarget: AudioBookmark?

  /// Rebuilds the model for the item now on screen. A retained model answers for the item it was
  /// built for, as `historyModel` does. Without a factory (the standalone harness) there is none.
  func reset(
    itemID: String, episodeID: String?, makeModel: ((String) -> AudioBookmarksModel)?
  ) {
    confirmation = nil
    renameTarget = nil
    model =
      PlayerBookmarkPresentation.isBookmarkable(itemID: itemID, episodeID: episodeID)
      ? makeModel?(itemID) : nil
  }

  func add(position: Double, chapters: [PlaybackChapter]) async {
    guard let model else { return }
    let outcome = await model.addBookmark(
      at: position,
      title: PlayerBookmarkPresentation.defaultTitle(position: position, chapters: chapters))
    confirmation = PlayerBookmarkPresentation.confirmation(for: outcome)
    confirmationGeneration += 1
  }

  func dismissConfirmation(generation: Int) {
    guard generation == confirmationGeneration else { return }
    confirmation = nil
  }

  func editConfirmed() {
    renameTarget = confirmation?.editableBookmark
    confirmation = nil
  }

  /// Returns the failure copy, if any, for the caller to show where it is.
  func rename(_ bookmark: AudioBookmark, to title: String) async -> String? {
    guard let model else { return nil }
    await model.rename(bookmark, to: title)
    return model.actionErrorMessage
  }
}

// MARK: - Confirmation banner

extension View {
  /// The add confirmation over the bottom of the player, with an Edit action for the title.
  func playerBookmarkConfirmation(_ controller: PlayerBookmarkController) -> some View {
    modifier(PlayerBookmarkConfirmationBanner(controller: controller))
  }

  func audioBookmarkRenameAlert(
    target: Binding<AudioBookmark?>, onSave: @escaping (AudioBookmark, String) -> Void
  ) -> some View {
    modifier(AudioBookmarkRenameAlert(target: target, onSave: onSave))
  }
}

/// A banner rather than an alert, like the queue confirmations: the listener meant to save, and an
/// alert would interrupt them for it. Unlike those it takes touches, because it carries Edit.
private struct PlayerBookmarkConfirmationBanner: ViewModifier {
  @Bindable var controller: PlayerBookmarkController
  @State private var errorMessage: String?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let confirmation = controller.confirmation
    let generation = controller.confirmationGeneration
    content
      .overlay(alignment: .bottom) {
        ZStack {
          if let confirmation {
            banner(confirmation)
              .transition(
                reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(
          reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.08), value: confirmation)
      }
      .sensoryFeedback(trigger: generation) { _, _ in
        guard let confirmation = controller.confirmation else { return nil }
        return confirmation.editableBookmark == nil ? .error : .success
      }
      .task(id: generation) {
        guard let confirmation else { return }
        AccessibilityNotification.Announcement(confirmation.message).post()
        try? await Task.sleep(for: .seconds(PlayerBookmarkPresentation.confirmationDuration))
        guard Task.isCancelled == false else { return }
        controller.dismissConfirmation(generation: generation)
      }
      .audioBookmarkRenameAlert(target: $controller.renameTarget) { bookmark, title in
        Task { errorMessage = await controller.rename(bookmark, to: title) }
      }
      .alert(
        "Bookmark",
        isPresented: Binding(
          get: { errorMessage != nil }, set: { if $0 == false { errorMessage = nil } })
      ) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
  }

  private func banner(_ confirmation: PlayerBookmarkPresentation.Confirmation) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: confirmation.editableBookmark == nil ? "exclamationmark.triangle" : "bookmark.fill")
        .font(WhirrTypeToken.headline.font)
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.08), in: Circle())
        .accessibilityHidden(true)

      Text(confirmation.message)
        .font(WhirrTypeToken.body.font.weight(.semibold))
        .lineLimit(2)

      if confirmation.editableBookmark != nil {
        Button("Edit") { controller.editConfirmed() }
          .font(WhirrTypeToken.body.font.weight(.semibold))
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
          .accessibilityHint("Renames this bookmark.")
      }
    }
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.vertical, WhirrSpacing.xSmall)
    .background(.regularMaterial, in: Capsule())
    .overlay {
      Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.bottom, WhirrSpacing.large)
  }
}

/// The one rename prompt, used by the confirmation's Edit and by the bookmark list.
private struct AudioBookmarkRenameAlert: ViewModifier {
  @Binding var target: AudioBookmark?
  let onSave: (AudioBookmark, String) -> Void
  @State private var draft = ""

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Bookmark",
        isPresented: Binding(get: { target != nil }, set: { if $0 == false { target = nil } })
      ) {
        TextField("Title", text: $draft)
        Button("Save") {
          if let target { onSave(target, draft) }
          target = nil
        }
        Button("Cancel", role: .cancel) { target = nil }
      }
      .onChange(of: target, initial: true) { _, newTarget in
        draft = newTarget?.title ?? ""
      }
  }
}

// MARK: - List

/// The chapter sheet's Bookmarks side: tap plays from the bookmark, swipe deletes, and the context
/// menu renames, each with a VoiceOver action.
struct PlayerBookmarksList: View {
  let model: AudioBookmarksModel
  let chapters: [PlaybackChapter]
  let onSelect: (AudioBookmark) -> Void

  @State private var renameTarget: AudioBookmark?
  @State private var errorMessage: String?

  var body: some View {
    let rows = PlayerBookmarkPresentation.rows(bookmarks: model.bookmarks, chapters: chapters)
    List {
      ForEach(rows) { row in
        bookmarkRow(row)
      }
    }
    .listStyle(.plain)
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView(
          "No Bookmarks",
          systemImage: "bookmark",
          description: Text("Choose Add Bookmark from the More menu while this book is playing.")
        )
      }
    }
    .audioBookmarkRenameAlert(target: $renameTarget) { bookmark, title in
      Task {
        await model.rename(bookmark, to: title)
        errorMessage = model.actionErrorMessage
      }
    }
    .alert(
      "Bookmark",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if $0 == false { errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func bookmarkRow(_ row: PlayerBookmarkRow) -> some View {
    ChapterRow(
      title: row.title,
      timingText: row.detailText,
      isCurrent: false,
      accessibilityLabel: row.accessibilityLabel,
      accessibilityValue: "",
      onSelect: { onSelect(row.bookmark) }
    )
    .accessibilityHint("Plays from this bookmark.")
    .swipeActions {
      Button(role: .destructive) {
        delete(row.bookmark)
      } label: {
        Label("Delete", systemImage: "trash")
      }
      // Explicit, as `SwipeActionTintTests` requires: this sheet inherits the expanded player's
      // `.tint(Color.primary)`, which otherwise fills the button with the glyph's own colour.
      .tint(.red)
    }
    .contextMenu {
      Button {
        renameTarget = row.bookmark
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      Button(role: .destructive) {
        delete(row.bookmark)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .accessibilityAction(named: "Rename") { renameTarget = row.bookmark }
    .accessibilityAction(named: "Delete") { delete(row.bookmark) }
  }

  private func delete(_ bookmark: AudioBookmark) {
    Task {
      await model.delete(bookmark)
      errorMessage = model.actionErrorMessage
    }
  }
}
