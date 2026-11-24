import AppModel
import DesignSystem
import Persistence
import ReaderCore
import SwiftUI

extension ReaderView {
  /// The reader's panels are ordinary modal screens, so they take the system's own sheet chrome
  /// (an inline title and the glass close button) rather than a hand-built header bar. Every
  /// panel applies its changes as they are made, so there is nothing for a confirm to commit.
  func panelSheet<Content: View>(
    title: String, isPresented: Binding<Bool>, @ViewBuilder content: () -> Content
  ) -> some View {
    NavigationStack {
      content()
        // The theme's accent is for the panel's controls. The sheet's chrome stays the app's, so
        // the close button matches the reader's own rather than taking a sepia or dark blue.
        .tint(palette.accentColor)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { isPresented.wrappedValue = false }
              .tint(AppChrome.tint)
          }
        }
    }
    .environment(\.colorScheme, theme == .dark ? .dark : .light)
    // The environment only reaches the content. The sheet is its own presentation, and the
    // cover's preference does not carry into it, so its glass took the device's appearance.
    .preferredColorScheme(ReaderPresentation.windowScheme(for: theme))
  }

  var tocSheet: some View {
    panelSheet(title: ReaderCopy.chapters, isPresented: $isShowingTOC) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(tocEntries.indices, id: \.self) { index in
            let entry = tocEntries[index]
            ReaderTOCRow(
              title: entry.title,
              pageLabel: model.pageLabel(for: entry),
              depth: entry.depth,
              // The row's label is already its title; its value is the page it starts on.
              accessibilityValue: model.pageLabel(for: entry).map(ReaderCopy.tocPageValue) ?? "",
              isCurrent: isCurrent(entry),
              currentIndicatorSystemImage: "bookmark.fill",
              theme: theme,
              onSelect: {
                Task {
                  await model.selectTOC(entry)
                  isShowingTOC = false
                }
              }
            )
            .accessibilityIdentifier(ReaderAccessibilityID.tocRow(index))
          }
        }
      }
      .background(palette.backgroundColor.ignoresSafeArea())
    }
  }

  var searchSheet: some View {
    panelSheet(title: ReaderCopy.search, isPresented: $isShowingSearch) {
      ReaderSearchPanel(renderer: renderer, toc: tocEntries, theme: theme) { id in
        pendingSearchHitID = id
        isShowingSearch = false
      }
    }
  }

}

/// On iOS 27 an iPad can present the appearance sheet at the side, leaving the whole page in view
/// beside it; iOS 26 keeps its default placement.
struct TrailingSheetPlacement: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 27.0, *) {
      content.presentationPlacement(.trailing)
    } else {
      content
    }
  }
}
