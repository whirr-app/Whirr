import SwiftUI
import Testing
import UIKit

/// The single owner of the key-window process global in App tests.
///
/// The key window is process-wide (the last `makeKeyAndVisible()` wins), so a forgotten restore
/// silently changes what every later suite hosts into. `withKeyWindow` restores from a `defer`
/// (also on a thrown error or cancellation) and reports a failed restore.
@MainActor
func withKeyWindow<T>(
  bounds: CGRect,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: (KeyWindowScope) async throws -> T
) async rethrows -> T {
  // SwiftUI builds no accessibility tree for a window no assistive technology is observing, so a
  // suite that walks one would blame the app. Idempotent: later calls are a global read.
  enableAccessibilityRuntimeForTests()

  let heldGate = await KeyWindowGate.shared.acquire()
  defer { KeyWindowGate.shared.release(ifHeld: heldGate) }

  let scope = KeyWindowScope(bounds: bounds)
  defer { scope.restore(sourceLocation: sourceLocation) }

  // Checks the gate rather than trusting it. `liveScopes` is process-wide, so a second open scope
  // while this one holds the window is the interference the gate exists to prevent.
  let live = KeyWindowCensus.shared.snapshot.liveScopes
  if heldGate, live != 1 {
    Issue.record(
      "\(live) key-window scopes are live while this one holds the process gate",
      sourceLocation: sourceLocation)
  }

  return try await body(scope)
}

/// Hands the key window to one caller at a time, process-wide.
///
/// `.serialized` only orders cases within one suite, but the key window and `PlayerLayoutProbe`
/// (a process-global store keyed by region) are per process, so parallel hosted-layout suites
/// measure each other: a chrome-layout case once read a scrubber frame a seek-feedback case had
/// just written.
///
/// A cancelled waiter resumes without the window and reports it, which beats an uninterruptible
/// test. A hung holder is bounded by its suite's `.timeLimit`, then the `defer` releases.
private nonisolated final class KeyWindowGate: @unchecked Sendable {
  static let shared = KeyWindowGate()

  private let lock = NSLock()
  private var isHeld = false
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

  /// `true` when the caller owns the window and must release it.
  func acquire() async -> Bool {
    let waiterID = UUID()
    var granted = false

    await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let takenImmediately = lock.withLock { () -> Bool in
            guard isHeld else {
              isHeld = true
              return true
            }
            waiters.append((waiterID, continuation))
            return false
          }
          if takenImmediately {
            granted = true
            continuation.resume()
            return
          }
          if Task.isCancelled { abandon(waiterID) }
        }
      },
      onCancel: { self.abandon(waiterID) })

    // A waiter resumed from the queue owns the window. One resumed by `abandon` does not, which is
    // the only way `claimed` is false after the queue has handed the window over.
    return granted || claimed(waiterID)
  }

  func release(ifHeld held: Bool) {
    guard held else { return }
    let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard waiters.isEmpty == false else {
        isHeld = false
        return nil
      }
      return waiters.removeFirst().continuation
    }
    next?.resume()
  }

  private func claimed(_ waiterID: UUID) -> Bool {
    lock.withLock { abandoned.remove(waiterID) == nil }
  }

  private var abandoned: Set<UUID> = []

  private func abandon(_ waiterID: UUID) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
      abandoned.insert(waiterID)
      return waiters.remove(at: index).continuation
    }
    continuation?.resume()
  }
}

/// A window owned by a single `withKeyWindow` call.
///
/// Not constructible outside this file. `withKeyWindow` owns its teardown.
@MainActor
final class KeyWindowScope {
  let window: UIWindow

  private let previousKeyWindow: UIWindow?
  private var isRestored = false

  fileprivate init(bounds: CGRect) {
    previousKeyWindow = KeyWindowScope.currentKeyWindow()

    // Adopting the host's scene lets the window take part in real layout. Without one, UIKit gives
    // no trait environment and the hosted view never lays out at `bounds`.
    guard let scene = previousKeyWindow?.windowScene ?? KeyWindowScope.hostWindowScene() else {
      preconditionFailure(
        "KeyWindowScope needs a connected UIWindowScene; the test host has none, so nothing it "
          + "hosts would lay out.")
    }
    let window = UIWindow(windowScene: scene)
    window.frame = bounds
    self.window = window

    KeyWindowCensus.shared.noteScopeEntered()
  }

  /// Hosts `rootView` and makes this scope's window key. Returns the hosting controller so a case
  /// can swap `rootView` without rebuilding the window. `additionalSafeAreaInsets` is set before
  /// installation, or a page placing chrome from the bottom inset would see it as a change.
  @discardableResult
  func host<Root: View>(
    _ rootView: Root, additionalSafeAreaInsets: UIEdgeInsets = .zero
  ) -> UIHostingController<Root> {
    let hostingController = UIHostingController(rootView: rootView)
    hostingController.additionalSafeAreaInsets = additionalSafeAreaInsets
    window.rootViewController = hostingController
    window.makeKeyAndVisible()
    hostingController.view.frame = window.bounds
    return hostingController
  }

  fileprivate func restore(sourceLocation: SourceLocation) {
    guard isRestored == false else { return }
    isRestored = true

    window.isHidden = true
    window.rootViewController = nil
    previousKeyWindow?.makeKeyAndVisible()

    KeyWindowCensus.shared.noteScopeExited()

    // Teardown check. `isKeyWindow` is the actual global, so reading it back is the only way to
    // confirm the restore took effect rather than merely being attempted.
    if window.isKeyWindow {
      Issue.record(
        "a key-window scope left its own window key after teardown",
        sourceLocation: sourceLocation)
    }
    if let previousKeyWindow, previousKeyWindow.isKeyWindow == false {
      Issue.record(
        "a key-window scope did not restore the previous key window",
        sourceLocation: sourceLocation)
    }
  }

  private static func currentKeyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }

  /// Fallback for a host with a scene but no key window yet. The first scope in a suite can run
  /// before anything has been made key.
  private static func hostWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
  }
}

/// Counts live key-window scopes so a suite can assert it owns none at teardown.
///
/// `@unchecked Sendable` over a lock, not an actor. The count must be readable from a synchronous
/// teardown path, and an actor would make every reader async.
final class KeyWindowCensus: @unchecked Sendable {
  static let shared = KeyWindowCensus()

  private struct State {
    var liveScopes = 0
    var peakLiveScopes = 0
    var enteredScopes = 0
  }

  struct Snapshot: Sendable {
    let liveScopes: Int
    let peakLiveScopes: Int
    let enteredScopes: Int
  }

  private let lock = NSLock()
  private var state = State()

  var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      liveScopes: state.liveScopes,
      peakLiveScopes: state.peakLiveScopes,
      enteredScopes: state.enteredScopes)
  }

  func noteScopeEntered() {
    lock.lock()
    defer { lock.unlock() }
    state.liveScopes += 1
    state.enteredScopes += 1
    state.peakLiveScopes = max(state.peakLiveScopes, state.liveScopes)
  }

  func noteScopeExited() {
    lock.lock()
    defer { lock.unlock() }
    state.liveScopes -= 1
  }
}

/// Fails if any key-window scope is still live.
///
/// Not called from cases: `liveScopes` counts the whole process, so a case reading it after its
/// scope closed races the next `acquire()`. The `liveScopes != 1` check inside `withKeyWindow`
/// proves `KeyWindowGate`'s bound while the window is owned. Per-case assertion needs a shard
/// that owns the process exclusively.
@MainActor
func expectNoLiveKeyWindows(sourceLocation: SourceLocation = #_sourceLocation) {
  let live = KeyWindowCensus.shared.snapshot.liveScopes
  #expect(
    live == 0,
    "\(live) key-window scope(s) outlived the case that created them",
    sourceLocation: sourceLocation)
}
