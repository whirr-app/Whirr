import Darwin
import Foundation

/// Turns the in-process accessibility runtime on, once, for the whole test process.
///
/// SwiftUI builds its accessibility tree only while an assistive technology is live. A test host
/// has none, so a hosted view reports `accessibilityElementCount() == 0` and every assertion
/// looks absent, like a regression.
///
/// `_AXSSetAutomationEnabled` (what simulator UI testing uses) is private, so it stays in the test
/// target; no public API does this for an unobserved window. Enabled once, never turned off: the
/// flag is global, so flipping it per case would change what a concurrent suite sees.
///
/// Returns whether the runtime is on. Tree suites should assert it, so a future OS renaming the
/// symbol reports "the tree was never built", not a page of missing labels.
@discardableResult
func enableAccessibilityRuntimeForTests() -> Bool {
  accessibilityRuntimeEnabled
}

/// A `let` rather than a flag and a lock. Swift runs a global's initialiser exactly once and blocks
/// concurrent callers until it finishes.
private let accessibilityRuntimeEnabled: Bool = {
  // Left loaded on purpose. The flag lives in the library's state, and unloading could leave that
  // state at the mercy of a later reload.
  guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return false }
  guard let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
  typealias SetAutomationEnabled = @convention(c) (Bool) -> Void
  unsafeBitCast(symbol, to: SetAutomationEnabled.self)(true)
  return true
}()
