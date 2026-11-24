import SwiftUI

/// The stored properties a component's caller actually supplied, as a value a `.dump` snapshot can
/// pin.
///
/// Dumping a `View` directly walks SwiftUI's private wrapper storage, which changes shape between
/// SDK releases (Xcode 27 renamed `@State`'s backing to `LazyState` and reshaped the `LocationBox`
/// behind `@Binding`). Two rules keep a snapshot to its subject:
///
/// - A `@Binding` is caller-supplied, so it is kept, projected down to the value it carries.
/// - Any other wrapper (`@State`, `@Environment`) is the view's own business, so it is dropped.
func semanticSurface(of subject: Any) -> [String: Any] {
  var surface: [String: Any] = [:]
  for child in Mirror(reflecting: subject).children {
    guard let label = child.label else { continue }
    let isWrapperStorage = label.hasPrefix("_")
    if isWrapperStorage && !(child.value is any ProjectableBinding) { continue }
    surface[String(label.drop(while: { $0 == "_" }))] = projectedValue(child.value)
  }
  return surface
}

/// A binding becomes the value it carries, reaching through an optional to find one, so that no
/// spelling of a caller-supplied binding leaves SwiftUI's storage in the snapshot. Only a binding
/// is unwrapped this way: every other optional keeps its shape, because whether a caller passed a
/// value at all is part of what the snapshot is pinning.
private func projectedValue(_ value: Any) -> Any {
  if let binding = value as? any ProjectableBinding { return binding.erasedWrappedValue }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .optional, let wrapped = mirror.children.first?.value,
    wrapped is any ProjectableBinding
  {
    return projectedValue(wrapped)
  }
  return value
}

/// Reads a `Binding`'s value without knowing the value's type, using only the binding's public
/// surface.
private protocol ProjectableBinding {
  var erasedWrappedValue: Any { get }
}

extension Binding: ProjectableBinding {
  fileprivate var erasedWrappedValue: Any { wrappedValue }
}
