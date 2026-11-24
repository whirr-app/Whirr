import SwiftUI

/// Which screens are currently in multiselect edit mode, so the shell can take its bottom player
/// accessory down while a selection's bulk actions occupy that space.
///
/// The shell's `.tabViewBottomAccessory` would draw the mini-player over `.bottomBar` bulk
/// actions, and only `LibraryShellView` can hide it, so selecting screens report here. Counted by
/// token: the accessory must not return while any screen is still selecting.
@MainActor @Observable
final class SelectionChromeModel {
  private var selectingScreens: Set<UUID> = []

  /// True while at least one screen is selecting.
  var isSelecting: Bool { !selectingScreens.isEmpty }

  func setSelecting(_ isSelecting: Bool, for screen: UUID) {
    if isSelecting {
      selectingScreens.insert(screen)
    } else {
      selectingScreens.remove(screen)
    }
  }
}

/// Reports one screen's selection state to the shell's `SelectionChromeModel`, keyed by a token
/// that lives as long as the screen does.
///
/// `initial: true` re-reports on every appearance. The environment lookup is optional: UI-harness
/// compositions mount these screens without a shell.
private struct SelectionChromeReporter: ViewModifier {
  let isSelecting: Bool
  @Environment(SelectionChromeModel.self) private var chrome: SelectionChromeModel?
  @State private var screen = UUID()

  func body(content: Content) -> some View {
    content
      .onChange(of: isSelecting, initial: true) { _, isSelecting in
        chrome?.setSelecting(isSelecting, for: screen)
      }
      .onDisappear { chrome?.setSelecting(false, for: screen) }
  }
}

extension View {
  /// Suppresses the shell's bottom player accessory while this screen is selecting, so the
  /// selection's `.bottomBar` actions are not covered by the mini-player.
  func hidesPlayerAccessory(whileSelecting isSelecting: Bool) -> some View {
    modifier(SelectionChromeReporter(isSelecting: isSelecting))
  }
}
