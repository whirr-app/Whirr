import SwiftUI

/// Replaces the trailing Done control when selection was opened to do one thing: the tick performs
/// that thing, and a separate close control leaves selection without doing it.
struct SelectionConfirmation {
  let label: String
  let isEnabled: Bool
  let confirm: () -> Void
  let cancel: () -> Void
}

/// Owns the shared selection toolbar so each screen supplies actions without declaring their
/// placements. An absent download action is spelled `download: { }`.
struct SelectionToolbar<Download: View, MarkFinished: View, More: View, Destructive: View>:
  ToolbarContent
{
  let screen: SelectionChromePresentation.Screen
  let selectedCount: Int
  let isEverythingSelected: Bool
  let isWorking: Bool
  let isSelectAllEnabled: Bool
  let onToggleSelectAll: () -> Void
  let confirmation: SelectionConfirmation?
  @ViewBuilder let download: () -> Download
  @ViewBuilder let markAsFinished: () -> MarkFinished
  @ViewBuilder let more: () -> More
  @ViewBuilder let destructive: () -> Destructive

  init(
    screen: SelectionChromePresentation.Screen,
    selectedCount: Int,
    isEverythingSelected: Bool,
    isWorking: Bool,
    isSelectAllEnabled: Bool,
    onToggleSelectAll: @escaping () -> Void,
    confirmation: SelectionConfirmation? = nil,
    @ViewBuilder download: @escaping () -> Download,
    @ViewBuilder markAsFinished: @escaping () -> MarkFinished,
    @ViewBuilder more: @escaping () -> More,
    @ViewBuilder destructive: @escaping () -> Destructive
  ) {
    self.screen = screen
    self.selectedCount = selectedCount
    self.isEverythingSelected = isEverythingSelected
    self.isWorking = isWorking
    self.isSelectAllEnabled = isSelectAllEnabled
    self.onToggleSelectAll = onToggleSelectAll
    self.confirmation = confirmation
    self.download = download
    self.markAsFinished = markAsFinished
    self.more = more
    self.destructive = destructive
  }

  @ToolbarContentBuilder
  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(SelectionChromePresentation.selectAllTitle(isEverythingSelected: isEverythingSelected)) {
        onToggleSelectAll()
      }
      .disabled(isWorking || !isSelectAllEnabled)
      .accessibilityIdentifier("\(accessibilityIdentifierPrefix).selection.all")
    }
    if let confirmation {
      ToolbarItem(placement: .topBarTrailing) {
        Button(role: .close) { confirmation.cancel() }
          .disabled(isWorking)
          .accessibilityIdentifier("\(accessibilityIdentifierPrefix).selection.cancel")
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(role: .confirm) { confirmation.confirm() }
          .tint(AppChrome.selectionMarkTint)
          .disabled(isWorking || !confirmation.isEnabled)
          .accessibilityLabel(confirmation.label)
          .accessibilityIdentifier("\(accessibilityIdentifierPrefix).selection.confirm")
      }
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        EditButton()
          .disabled(isWorking)
          .accessibilityIdentifier("\(accessibilityIdentifierPrefix).selection.done")
      }
    }
    ToolbarItemGroup(placement: .bottomBar) {
      download()
      markAsFinished()
      Spacer()
      more()
    }
    // ToolbarSpacer is toolbar content rather than a View, so it belongs beside the group and
    // keeps the destructive control in its own Liquid Glass group.
    ToolbarSpacer(.fixed, placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      destructive()
    }
  }

  private var accessibilityIdentifierPrefix: String { screen.accessibilityIdentifierPrefix }
}

/// The control that enters selection, so every multiselect screen offers it the same way: label,
/// glyph, animation and dimming.
///
/// A `View` rather than `ToolbarContent` because the Library's lives in the shell's toolbar while
/// the others declare their own; each call site wraps it in the `ToolbarItem` it needs.
struct SelectionEntryButton: View {
  let screen: SelectionChromePresentation.Screen
  /// False when the list is empty. The control dims rather than disappearing, which would shift
  /// everything beside it.
  let isEnabled: Bool
  let beginSelecting: () -> Void

  var body: some View {
    Button(SelectionChromePresentation.entryTitle, systemImage: "checkmark.circle") {
      withAnimation { beginSelecting() }
    }
    .disabled(!isEnabled)
    .accessibilityLabel(screen.invitation)
    .accessibilityIdentifier("\(screen.accessibilityIdentifierPrefix).selection.begin")
  }
}

extension View {
  /// Tints the multiselect circles a `List(selection:)` draws down its leading edge.
  ///
  /// Belongs on the list, not the screen: the toolbar's own controls keep the neutral chrome tint,
  /// which reads on the bottom bar's glass. A ternary rather than an `if`, because a conditional
  /// modifier re-creates the list and loses its scroll position on entering selection.
  func selectionMarkTint(isSelecting: Bool) -> some View {
    tint(isSelecting ? AppChrome.selectionMarkTint : AppChrome.tint)
  }

  /// Applies selection-aware navigation chrome without branching, preserving view identity and
  /// scroll position while entering or leaving selection.
  func selectionChrome(
    isSelecting: Bool,
    selectionTitle: String,
    title: String,
    titleDisplayMode: ToolbarTitleDisplayMode = .automatic
  ) -> some View {
    navigationTitle(isSelecting ? selectionTitle : title)
      .toolbarTitleDisplayMode(isSelecting ? .inline : titleDisplayMode)
  }
}
