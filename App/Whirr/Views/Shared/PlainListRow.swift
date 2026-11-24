import SwiftUI

extension View {
  /// Full-bleed, separator-free content sitting in a plain `List`.
  ///
  /// Zeroing `listRowInsets` also zeroes the only vertical spacing a plain `List` contributes, so
  /// any rhythm the screen wants above and below the row has to be stated here rather than
  /// inherited.
  func plainListRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
    listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}
