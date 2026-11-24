import DesignSystem
import SwiftUI

/// The native replacement for the compact List's A-Z rail. A Menu keeps the control near the mode
/// picker with a normal touch target and the same complete alphabet as the compact list, without a
/// custom overlay on scroll content.
struct LibraryBrowseAlphabetJumpMenu: View {
  let availableSectionIDs: Set<String>
  let isQueryEffective: Bool
  let onSelect: (String) -> Void

  var body: some View {
    if LibraryBrowseLayoutPresentation.indexMenuIsVisible(isQueryEffective: isQueryEffective) {
      Menu {
        ForEach(LibraryBrowsePresentation.alphabetIndexTitles, id: \.self) { sectionID in
          Button(sectionID) {
            onSelect(sectionID)
          }
          .disabled(availableSectionIDs.contains(sectionID) == false)
        }
      } label: {
        Label("Jump to letter", systemImage: "textformat.abc")
          .frame(
            minWidth: WhirrMetric.minimumTouchTarget,
            minHeight: WhirrMetric.minimumTouchTarget
          )
          .contentShape(.rect)
      }
      .accessibilityIdentifier(LibraryAccessibilityID.indexMenu)
    }
  }
}
