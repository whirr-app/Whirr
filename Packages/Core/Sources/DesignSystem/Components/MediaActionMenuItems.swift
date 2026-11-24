import SwiftUI

/// The one renderer for an item's action rows: the show page's episode rows, the episode card, and
/// the shared long-press menu for books and episodes all draw through it, so a row's title, glyph,
/// role and divider placement cannot differ between them.
///
/// Equatable on `sections` alone. A presented menu is often hosted over a view that re-renders on
/// a playhead tick, and rebuilding its source visibly pulses the menu's glass; the closure is
/// excluded because it is re-created on every pass.
public struct MediaActionMenuItems: View, Equatable {
  let sections: [[MediaContextAction]]
  let onSelectAction: (MediaContextAction) -> Void

  public init(
    sections: [[MediaContextAction]], onSelectAction: @escaping (MediaContextAction) -> Void
  ) {
    self.sections = sections
    self.onSelectAction = onSelectAction
  }

  public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sections == rhs.sections
  }

  public var body: some View {
    ForEach(sections.indices, id: \.self) { sectionIndex in
      if sectionIndex > sections.startIndex {
        Divider()
      }
      ForEach(sections[sectionIndex]) { action in
        MediaActionMenuItem(action: action, onSelectAction: onSelectAction)
      }
    }
  }
}

/// One row, or one submenu of rows.
struct MediaActionMenuItem: View {
  let action: MediaContextAction
  let onSelectAction: (MediaContextAction) -> Void

  var body: some View {
    if action.isSubmenu, action.childrenStyle == .controlGroup {
      ControlGroup { children }
    } else if action.isSubmenu {
      Menu {
        if let header = action.childrenTitle {
          Section(header) { children }
        } else {
          children
        }
      } label: {
        title
      }
      .modifier(MediaActionRowOptions(action: action))
    } else {
      Button(role: action.role == .destructive ? .destructive : nil) {
        onSelectAction(action)
      } label: {
        title
      }
      .modifier(MediaActionRowOptions(action: action))
    }
  }

  private var children: some View {
    ForEach(action.children) { child in
      MediaActionMenuItem(action: child, onSelectAction: onSelectAction)
    }
  }

  /// A submenu's choices can be bare names (e-reader devices), which a glyph would only repeat.
  @ViewBuilder private var title: some View {
    if let compact = action.compactLabel {
      Label(compact, systemImage: action.systemImage)
        .accessibilityLabel(Text(action.label))
    } else if action.systemImage.isEmpty {
      Text(action.label)
    } else {
      Label(action.label, systemImage: action.systemImage)
    }
  }
}

/// The per-row options, each applied only when set, so a plain row is drawn exactly as a bare
/// `Button` would be.
private struct MediaActionRowOptions: ViewModifier {
  let action: MediaContextAction

  func body(content: Content) -> some View {
    let row =
      content
      .disabled(action.isEnabled == false)
      .accessibilityHint(action.hint)
    if let identifier = action.accessibilityIdentifier {
      if let limit = action.titleLineLimit {
        row.accessibilityIdentifier(identifier).lineLimit(limit)
      } else {
        row.accessibilityIdentifier(identifier)
      }
    } else if let limit = action.titleLineLimit {
      row.lineLimit(limit)
    } else {
      row
    }
  }
}
