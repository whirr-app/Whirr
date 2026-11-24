import AppModel
import Persistence
import SwiftUI

/// The identity of one rendered book cover. The occurrence is supplied by the
/// owning surface (shelf, row, or grid tile), so two copies of an item can coexist in one
/// namespace without one source silently winning.
struct BookZoomTransitionSource: Hashable, Sendable {
  let itemID: String
  let occurrence: String

  /// Keep the matched-transition id typed. A string made by concatenating two independently
  /// controlled values can collide (`a:b`/`a` + `b`), while SwiftUI accepts any `Hashable` id.
  struct ID: Hashable, Sendable {
    let itemID: String
    let occurrence: String
  }

  var id: ID {
    ID(itemID: itemID, occurrence: occurrence)
  }
}

/// The source-selection rule is kept independent of SwiftUI so every caller can preserve its
/// existing non-book action and tests can exercise Reduce Motion without constructing a namespace.
nonisolated enum BookZoomTransitionPolicy {
  /// Master switch, off: the iOS 26 system zoom pop finalises as a cancelled transition and clears
  /// a touch begun on Home, leaving scrolling dead until the finger lifts (FB19601591,
  /// FB21078443, unfixed through iOS 27 beta 8). Re-check on the iOS 27 release;
  /// flipping this is the only change needed.
  static let isAvailable = false

  static func supports(_ category: ItemMediaCategory) -> Bool {
    category == .audiobook || category == .ebook
  }

  static func shouldUseSource(for category: ItemMediaCategory, isEnabled: Bool) -> Bool {
    isEnabled && supports(category)
  }
}

/// The long-lived half of the zoom hand-off. It is a reference so that the environment context
/// below stays comparable by identity: a closure stored directly in the environment value would
/// read as changed on every `LibraryShellView` body evaluation and invalidate every book cover on
/// screen. The relay also records which covers have actually applied their matched source, so a
/// push can wait for the tapped cover instead of racing SwiftUI's next update.
@MainActor
final class BookZoomTransitionRelay {
  typealias SelectBook = (
    ItemSummary, BookZoomTransitionSource?, CoverImageView.Role, CGFloat
  ) -> Void

  var onSelectBook: SelectBook = { _, _, _, _ in }
  var onDestinationDisappeared: (BookZoomTransitionSource) -> Void = { _ in }

  private var attachedSources: Set<BookZoomTransitionSource> = []
  private var attachmentWaiters: [BookZoomTransitionSource: CheckedContinuation<Void, Never>] =
    [:]

  func isAttached(_ source: BookZoomTransitionSource) -> Bool {
    attachedSources.contains(source)
  }

  func sourceDidAttach(_ source: BookZoomTransitionSource) {
    attachedSources.insert(source)
    attachmentWaiters.removeValue(forKey: source)?.resume()
  }

  func sourceDidDetach(_ source: BookZoomTransitionSource) {
    attachedSources.remove(source)
  }

  /// Suspends until `source` has applied its matched source, or until `timeout` elapses. The
  /// timeout is the safety net for a source whose cover is not in the tree at all; the push then
  /// proceeds without a zoom rather than never happening.
  func waitForAttachment(of source: BookZoomTransitionSource, timeout: Duration) async {
    guard attachedSources.contains(source) == false else { return }
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard Task.isCancelled == false else { return }
      self?.attachmentWaiters.removeValue(forKey: source)?.resume()
    }
    await withCheckedContinuation { continuation in
      attachmentWaiters.removeValue(forKey: source)?.resume()
      attachmentWaiters[source] = continuation
    }
    timeoutTask.cancel()
  }
}

/// App presentation context shared by every book entry surface and its navigation destinations.
/// `Namespace.ID` belongs at this layer; it never crosses into AppModel or Core.
///
/// Equatable so SwiftUI can skip the many cards, rows and tiles reading this through
/// `@Environment` when it is unchanged. `nonisolated` because SwiftUI's comparison doesn't run as
/// main-actor code.
nonisolated struct BookZoomTransitionContext: Equatable {
  let namespace: Namespace.ID
  let isEnabled: Bool
  let relay: BookZoomTransitionRelay

  static func == (lhs: BookZoomTransitionContext, rhs: BookZoomTransitionContext) -> Bool {
    lhs.namespace == rhs.namespace && lhs.isEnabled == rhs.isEnabled && lhs.relay === rhs.relay
  }

  func source(item: ItemSummary, occurrence: String) -> BookZoomTransitionSource? {
    guard BookZoomTransitionPolicy.shouldUseSource(for: item.category, isEnabled: isEnabled)
    else { return nil }
    return BookZoomTransitionSource(itemID: item.serverItemId, occurrence: occurrence)
  }

  @MainActor
  func selectBook(
    _ item: ItemSummary,
    occurrence: String,
    artworkRole: CoverImageView.Role,
    displaySize: CGFloat
  ) -> Bool {
    guard BookZoomTransitionPolicy.supports(item.category) else { return false }
    relay.onSelectBook(item, source(item: item, occurrence: occurrence), artworkRole, displaySize)
    return true
  }
}

private struct BookZoomTransitionContextKey: EnvironmentKey {
  static let defaultValue: BookZoomTransitionContext? = nil
}

private struct BookZoomTransitionOccurrencePrefixKey: EnvironmentKey {
  static let defaultValue = "root"
}

private struct BookZoomActiveSourcesKey: EnvironmentKey {
  static let defaultValue: Set<BookZoomTransitionSource> = []
}

extension EnvironmentValues {
  var bookZoomTransitionContext: BookZoomTransitionContext? {
    get { self[BookZoomTransitionContextKey.self] }
    set { self[BookZoomTransitionContextKey.self] = newValue }
  }

  var bookZoomTransitionOccurrencePrefix: String {
    get { self[BookZoomTransitionOccurrencePrefixKey.self] }
    set { self[BookZoomTransitionOccurrencePrefixKey.self] = newValue }
  }

  /// The covers that currently carry a matched transition source: the one just tapped, plus any
  /// whose destination is still on a navigation stack. Everything else renders as a plain cover.
  var bookZoomActiveSources: Set<BookZoomTransitionSource> {
    get { self[BookZoomActiveSourcesKey.self] }
    set { self[BookZoomActiveSourcesKey.self] = newValue }
  }
}

/// Applies the source API only to the cover in a transition: a standing
/// `matchedTransitionSource` on every shelf cover means dozens of live sources and a tile UIKit
/// keeps tracking after a return (FB21961572: the source lags its neighbours when the grid is
/// scrolled right after the pop). Attached on tap, detached once the destination has gone.
///
/// The source is a mirror laid over the cover, so attaching never re-identifies it (artwork, state
/// and keyed task survive; no placeholder flash after a memory-cache eviction). A clear colour
/// won't do: the zoom snapshots rendered content and treats a source rendering nothing as absent,
/// zooming from screen centre. One modifier holding the conditional also makes Reduce Motion a
/// true opt-out.
private struct BookZoomTransitionSourceModifier: ViewModifier {
  let source: BookZoomTransitionSource?
  @Environment(\.bookZoomTransitionContext) private var context
  @Environment(\.bookZoomActiveSources) private var activeSources

  private var attachedSource: BookZoomTransitionSource? {
    guard let context, context.isEnabled, let source, activeSources.contains(source)
    else { return nil }
    return source
  }

  func body(content: Content) -> some View {
    content.overlay {
      if let context, let attachedSource {
        content
          .matchedTransitionSource(id: attachedSource.id, in: context.namespace)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          // The push waits for this: the source must exist before the destination is pushed or
          // the system has nothing to zoom from.
          .onAppear { context.relay.sourceDidAttach(attachedSource) }
          .onDisappear { context.relay.sourceDidDetach(attachedSource) }
      }
    }
  }
}

extension View {
  func bookZoomTransitionSource(_ source: BookZoomTransitionSource?) -> some View {
    modifier(BookZoomTransitionSourceModifier(source: source))
  }

  @ViewBuilder
  func bookZoomTransitionDestination(_ source: BookZoomTransitionSource?) -> some View {
    modifier(BookZoomTransitionDestinationModifier(source: source))
  }
}

private struct BookZoomTransitionDestinationModifier: ViewModifier {
  /// This value is only the initial proposal. SwiftUI may rebuild the destination modifier when
  /// its parent path changes (for example while a child route is pushed), but the destination must
  /// keep the source that belonged to this pushed view for the complete forward/interactive-back
  /// transition. `@State` gives each destination view identity its own one-time capture and also
  /// makes a source-less deep link stay source-less if a later selection changes the registry.
  @State private var capturedSource: BookZoomTransitionSource?
  @Environment(\.bookZoomTransitionContext) private var context

  init(source: BookZoomTransitionSource?) {
    _capturedSource = State(initialValue: source)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if let context, context.isEnabled, let capturedSource {
      content
        .navigationTransition(.zoom(sourceID: capturedSource.id, in: context.namespace))
        // Fires after the pop animation has finished, which is the earliest moment the source
        // cover may stop being a matched source without breaking the return.
        .onDisappear { context.relay.onDestinationDisappeared(capturedSource) }
    } else {
      content
    }
  }
}

/// The registry owns only the short hand-off between a source tap and the destination's first
/// render. Once the destination modifier captures its source, it no longer reads this object.
/// Entries are path-scoped so two copies of one item, including nested copies of the same route,
/// cannot retarget one another.
@MainActor
final class BookZoomTransitionRegistry {
  struct Key: Hashable {
    fileprivate let token: UUID
    let section: NavigationModel.Section
    /// The path after the selected route has been appended. Kept as `path` for diagnostics and
    /// tests; the registry also stores the parent path to distinguish pending work from an active
    /// destination while an asynchronous palette is being prepared.
    let path: [NavigationModel.Route]
  }

  private enum State {
    case prepared
    case active
  }

  private struct Entry {
    let source: BookZoomTransitionSource
    let originPath: [NavigationModel.Route]
    let destinationPath: [NavigationModel.Route]
    var state: State
  }

  private var entries: [Key: Entry] = [:]

  func prepare(
    section: NavigationModel.Section,
    path: [NavigationModel.Route],
    source: BookZoomTransitionSource
  ) -> Key {
    let key = Key(token: UUID(), section: section, path: path)
    let originPath = Array(path.dropLast())
    entries[key] = Entry(
      source: source,
      originPath: originPath,
      destinationPath: path,
      state: .prepared)
    return key
  }

  func activate(_ key: Key) {
    guard var entry = entries[key], entry.state == .prepared else { return }
    entry.state = .active
    entries[key] = entry
  }

  /// Returns the source for the destination currently being constructed. The complete path is
  /// required: a source-less deep link to a repeated item must never inherit an ancestor's source.
  /// Existing parent destinations retain their source in the destination modifier's `@State` while
  /// a child is pushed, so no prefix fallback is needed here.
  func sourceForDestination(
    section: NavigationModel.Section,
    path: [NavigationModel.Route],
    route: NavigationModel.Route
  ) -> (key: Key, source: BookZoomTransitionSource)? {
    entries.first(where: { key, entry in
      key.section == section
        && entry.state == .active
        && entry.destinationPath.last == route
        && entry.destinationPath == path
    })
    .map { key, entry in (key: key, source: entry.source) }
  }

  /// Exact lookup retained for callers/tests that need to ask whether one captured path is still
  /// registered. Destination construction uses `sourceForDestination` above.
  func source(
    section: NavigationModel.Section,
    path: [NavigationModel.Route]
  ) -> (key: Key, source: BookZoomTransitionSource)? {
    guard
      let match = entries.first(where: { key, entry in
        key.section == section && key.path == path && entry.state == .active
      })
    else { return nil }
    return (match.key, match.value.source)
  }

  /// Whether any active destination still owns `source`. A source stays attached while this is
  /// true, so a detail that has a child pushed on top of it keeps its return animation.
  func hasActiveEntry(for source: BookZoomTransitionSource) -> Bool {
    entries.contains { _, entry in entry.state == .active && entry.source == source }
  }

  /// Cancellation only drops a preparation. An already active destination owns its source until
  /// path reconciliation below, so cancelling the task that launched it cannot break an
  /// interactive return animation.
  func dropPreparation(_ key: Key) {
    guard entries[key]?.state == .prepared else { return }
    entries.removeValue(forKey: key)
  }

  /// NavigationStack can remove a route during an interactive pop and then put it back when the
  /// gesture is cancelled. The wrapper has already captured its source, so it is safe (and
  /// correct) to retire the registry hand-off at the first real path removal. Parent entries stay
  /// alive while a child is pushed; entries in another tab are untouched because this method is
  /// called only for the section whose path changed.
  func reconcile(section: NavigationModel.Section, path: [NavigationModel.Route]) {
    entries = entries.filter { key, entry in
      guard key.section == section else { return true }
      switch entry.state {
      case .prepared:
        // A pending selection is valid only while its captured parent path is still current.
        return entry.originPath == path
      case .active:
        return path.starts(with: entry.destinationPath)
      }
    }
  }

  func retire(_ key: Key) {
    entries.removeValue(forKey: key)
  }
}
