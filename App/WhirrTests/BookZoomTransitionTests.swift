import AppModel
import Testing

@testable import Whirr

@Suite("Book detail zoom transition")
@MainActor
struct BookZoomTransitionTests {
  @Test("the zoom is switched off until its return-scroll cost is understood")
  func zoomIsUnavailable() {
    #expect(BookZoomTransitionPolicy.isAvailable == false)
  }

  @Test("only enabled book categories receive a transition source")
  func sourceSelectionPolicy() {
    #expect(BookZoomTransitionPolicy.shouldUseSource(for: .audiobook, isEnabled: true))
    #expect(BookZoomTransitionPolicy.shouldUseSource(for: .ebook, isEnabled: true))
    #expect(
      BookZoomTransitionPolicy.shouldUseSource(for: .podcast, isEnabled: true) == false)
    #expect(
      BookZoomTransitionPolicy.shouldUseSource(for: .audiobook, isEnabled: false) == false)
  }

  @Test("registry activates only the complete captured route")
  func registryUsesCompleteRoute() {
    let registry = BookZoomTransitionRegistry()
    let source = BookZoomTransitionSource(itemID: "book-1", occurrence: "home/recent/book-1")
    let route = NavigationModel.Route.itemDetail(itemID: "book-1")
    let key = registry.prepare(section: .home, path: [route], source: source)

    #expect(registry.source(section: .home, path: [route]) == nil)
    registry.activate(key)
    #expect(registry.source(section: .home, path: [route])?.source == source)
    #expect(
      registry.source(
        section: .home,
        path: [route, .author(id: "author-1", libraryID: "library-1")]
      ) == nil)
  }

  @Test("nested repeated details keep independent sources")
  func nestedRepeatedDetailsUseTheirOwnSource() {
    let registry = BookZoomTransitionRegistry()
    let book = NavigationModel.Route.itemDetail(itemID: "book-a")
    let author = NavigationModel.Route.author(id: "author-1", libraryID: "library-1")
    let firstSource = BookZoomTransitionSource(itemID: "book-a", occurrence: "home/book-a")
    let secondSource = BookZoomTransitionSource(itemID: "book-a", occurrence: "author/book-a")

    let firstKey = registry.prepare(section: .home, path: [book], source: firstSource)
    registry.activate(firstKey)
    let secondPath = [book, author, book]
    let secondKey = registry.prepare(section: .home, path: secondPath, source: secondSource)
    registry.activate(secondKey)

    #expect(
      registry.sourceForDestination(section: .home, path: [book], route: book)?.source
        == firstSource)
    #expect(
      registry.sourceForDestination(section: .home, path: secondPath, route: book)?.source
        == secondSource)
  }

  @Test("path reconciliation retains parents and clears removed sources")
  func pathReconciliationCleansOnlyRemovedRoutes() {
    let registry = BookZoomTransitionRegistry()
    let book = NavigationModel.Route.itemDetail(itemID: "book-a")
    let author = NavigationModel.Route.author(id: "author-1", libraryID: "library-1")
    let source = BookZoomTransitionSource(itemID: "book-a", occurrence: "home/book-a")
    let key = registry.prepare(section: .home, path: [book], source: source)
    registry.activate(key)

    registry.reconcile(section: .home, path: [book, author])
    #expect(registry.source(section: .home, path: [book])?.source == source)

    // Switching sections does not retire a still-mounted tab's source.
    registry.reconcile(section: .library, path: [])
    #expect(registry.source(section: .home, path: [book])?.source == source)

    registry.reconcile(section: .home, path: [])
    #expect(registry.source(section: .home, path: [book]) == nil)
    // A later source-less deep link cannot recover the removed hand-off.
    #expect(
      registry.sourceForDestination(section: .home, path: [book], route: book) == nil)
  }

  @Test("cancelled or invalid preparation cannot be activated")
  func cancelledPreparationIsDropped() {
    let registry = BookZoomTransitionRegistry()
    let book = NavigationModel.Route.itemDetail(itemID: "book-a")
    let source = BookZoomTransitionSource(itemID: "book-a", occurrence: "home/book-a")
    let key = registry.prepare(section: .home, path: [book], source: source)

    registry.reconcile(section: .home, path: [.homeMore(section: .recentlyAdded, filter: .all)])
    registry.activate(key)

    #expect(registry.source(section: .home, path: [book]) == nil)
  }

  @Test("an active entry keeps its source attached until the destination is gone")
  func activeEntryKeepsSourceAttached() {
    let registry = BookZoomTransitionRegistry()
    let book = NavigationModel.Route.itemDetail(itemID: "book-a")
    let author = NavigationModel.Route.author(id: "author-1", libraryID: "library-1")
    let source = BookZoomTransitionSource(itemID: "book-a", occurrence: "home/book-a")
    let key = registry.prepare(section: .home, path: [book], source: source)

    // A preparation that has not activated does not count as an owner.
    #expect(registry.hasActiveEntry(for: source) == false)
    registry.activate(key)
    #expect(registry.hasActiveEntry(for: source))

    // A child pushed on top fires the destination's onDisappear but must not detach the source.
    registry.reconcile(section: .home, path: [book, author])
    #expect(registry.hasActiveEntry(for: source))

    registry.reconcile(section: .home, path: [])
    #expect(registry.hasActiveEntry(for: source) == false)
  }

  @Test("relay resumes a waiting push once the cover attaches, or on timeout")
  func relayAttachmentHandoff() async {
    let relay = BookZoomTransitionRelay()
    let source = BookZoomTransitionSource(itemID: "book-a", occurrence: "home/book-a")

    // Already attached: no suspension.
    relay.sourceDidAttach(source)
    #expect(relay.isAttached(source))
    await relay.waitForAttachment(of: source, timeout: .seconds(5))

    // Attached while waiting: the wait ends because the cover attached. The timeout is far
    // beyond anything the suite tolerates, so a wait that returns at all proves the hand-off;
    // asserting on wall-clock time instead is flaky when the full suite starves the main actor.
    relay.sourceDidDetach(source)
    #expect(relay.isAttached(source) == false)
    Task { @MainActor in
      relay.sourceDidAttach(source)
    }
    await relay.waitForAttachment(of: source, timeout: .seconds(600))
    #expect(relay.isAttached(source))

    // Never attached: the timeout releases the push instead of holding it forever.
    let other = BookZoomTransitionSource(itemID: "book-b", occurrence: "home/book-b")
    await relay.waitForAttachment(of: other, timeout: .milliseconds(20))
    #expect(relay.isAttached(other) == false)
  }

  @Test("source identity retains its rendered occurrence")
  func sourceIdentityIncludesOccurrenceAndItem() {
    let first = BookZoomTransitionSource(itemID: "book-1", occurrence: "home/shelf-a/book-1")
    let second = BookZoomTransitionSource(itemID: "book-1", occurrence: "home/shelf-b/book-1")

    #expect(first != second)
    #expect(first.id != second.id)
  }
}
