import SwiftUI

private struct WindowHorizontalSizeClassKey: EnvironmentKey {
  static let defaultValue: UserInterfaceSizeClass? = nil
}

extension EnvironmentValues {
  /// The horizontal size class of the window, published by the app's roots.
  ///
  /// `\.horizontalSizeClass` describes the reading container, so inside a sheet it reads the
  /// sheet's own decision back: on `Whirr Test iPad` in portrait a `.form` sheet (~570 pt) reports
  /// `.compact` while the window's `.page` sheet (834 pt) reports `.regular`, so asking for
  /// `.form` at regular width would narrow itself into compact. This custom value is inherited
  /// by sheet content, not recomputed. Sheet sizing reads it; content within a pane still reads
  /// `\.horizontalSizeClass`. `nil` (no root published) is treated as compact.
  var windowHorizontalSizeClass: UserInterfaceSizeClass? {
    get { self[WindowHorizontalSizeClassKey.self] }
    set { self[WindowHorizontalSizeClassKey.self] = newValue }
  }
}

extension View {
  /// Publishes `sizeClass` as the window's, for every sheet raised beneath this view. Only an app
  /// root may call this, since it is only meaningful if nothing between the window and a sheet has
  /// redefined it.
  func windowHorizontalSizeClass(_ sizeClass: UserInterfaceSizeClass?) -> some View {
    environment(\.windowHorizontalSizeClass, sizeClass)
  }
}
