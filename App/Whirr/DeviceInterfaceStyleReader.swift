import SwiftUI
import UIKit

/// Reads the scene's device appearance independently of the window's reader-theme override.
/// App appearance in System mode must not inherit a temporary Light/Dark reader preference.
struct DeviceInterfaceStyleReader: UIViewRepresentable {
  let onChange: (ColorScheme) -> Void

  func makeUIView(context: Context) -> ReaderView {
    ReaderView(onChange: onChange)
  }

  func updateUIView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
  }

  final class ReaderView: UIView {
    var onChange: (ColorScheme) -> Void
    private var registration: (any UITraitChangeRegistration)?

    init(onChange: @escaping (ColorScheme) -> Void) {
      self.onChange = onChange
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    /// The scene is only reachable once this view is in a window, and a view moved out of one keeps
    /// no registration on a scene it may never return to.
    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard let scene = window?.windowScene else {
        registration = nil
        return
      }
      if registration == nil {
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
          [weak self] (_: UIWindowScene, _: UITraitCollection) in
          self?.report()
        }
      }
      report()
    }

    private func report() {
      guard let scene = window?.windowScene else { return }
      onChange(scene.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }
  }
}
