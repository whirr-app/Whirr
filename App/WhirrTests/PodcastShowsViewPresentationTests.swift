import AppModel
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

@Suite("Podcast shows view presentation")
struct PodcastShowsViewPresentationTests {
  private nonisolated static func show(_ id: String) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "podcast", title: id, author: "Publisher \(id)",
      durationSeconds: nil, category: .podcast)
  }

  @Test func reorderBecomesImmediateUnderReduceMotion() {
    #expect(PodcastShowsViewPresentation.reorderAnimation(reduceMotion: true) == nil)
    #expect(PodcastShowsViewPresentation.reorderAnimation(reduceMotion: false) == .snappy)
  }

  @Test func allShowsUsesOrderedSnapshotWithoutResorting() {
    // Not alphabetical: a re-sort would put "alpha" first and fail this test.
    let shows = [Self.show("zulu"), Self.show("alpha"), Self.show("mike")]
    let snapshot = PodcastShowsSnapshot(mode: .custom, shows: shows)

    #expect(PodcastShowsViewPresentation.shows(in: .loaded(snapshot)) == shows)
    #expect(PodcastShowsViewPresentation.shows(in: .partiallySynced(snapshot)) == shows)
    #expect(PodcastShowsViewPresentation.shows(in: .staleOffline(snapshot)) == shows)
    #expect(PodcastShowsViewPresentation.shows(in: .loading).isEmpty)
    #expect(PodcastShowsViewPresentation.shows(in: .empty).isEmpty)
    #expect(PodcastShowsViewPresentation.shows(in: .error).isEmpty)
  }

  @Test("loading and empty promises pull, while error offers a real retry action")
  func statePlaceholdersStayOverTheScrollHostAndErrorCanRetry() {
    let loading = PodcastShowsViewPresentation.placeholder(for: .loading)
    #expect(loading?.allowsHitTesting == false)
    #expect(loading?.action == nil)

    let empty = PodcastShowsViewPresentation.placeholder(for: .empty)
    #expect(empty?.allowsHitTesting == false)
    #expect(empty?.action == nil)

    let error = PodcastShowsViewPresentation.placeholder(for: .error)
    #expect(error?.allowsHitTesting == true)
    #expect(error?.action == .retry)
    #expect(error?.action?.label == "Retry")

    #expect(PodcastShowsViewPresentation.placeholder(for: .loading)?.action == nil)
  }

  @Test func readOnlyModeAllowsSelectionAndContextMenu() {
    #expect(PodcastShowsViewPresentation.tileIsSelectable(isEditing: false))
    #expect(PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: false))
  }

  @Test func editingModeSuppressesSelectionAndContextMenu() {
    #expect(PodcastShowsViewPresentation.tileIsSelectable(isEditing: true) == false)
    #expect(PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: true) == false)
  }

  @Test func editingIsUnavailableWhileSyncIsRunning() {
    let snapshot = PodcastShowsSnapshot(mode: .alphabetical, shows: [Self.show("alpha")])

    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .partiallySynced(snapshot)) == false)
    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .loaded(snapshot)))
    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .staleOffline(snapshot)))
    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .loading) == false)
    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .empty) == false)
    #expect(PodcastShowsViewPresentation.editingIsAllowed(in: .error) == false)
  }

  // MARK: - Editing mode and drag reorder

  @Test func editButtonTogglesEditingAndDoneLabels() {
    var session = PodcastShowsEditingSession()
    #expect(session.isEditing == false)
    #expect(PodcastShowsViewPresentation.editButtonTitle(isEditing: session.isEditing) == "Edit")
    #expect(
      PodcastShowsViewPresentation.editButtonIsAvailable(isEditing: false, isEditingAllowed: true))
    // A running sync makes the whole grid unarrangeable, so there is nothing to enter.
    #expect(
      PodcastShowsViewPresentation.editButtonIsAvailable(isEditing: false, isEditingAllowed: false)
        == false)

    session.beginEditing(order: ["a", "b", "c"])
    #expect(session.isEditing)
    #expect(session.order == ["a", "b", "c"])
    #expect(PodcastShowsViewPresentation.editButtonTitle(isEditing: session.isEditing) == "Done")
    // Done stays reachable whatever the gate says, so editing can never trap the user.
    #expect(
      PodcastShowsViewPresentation.editButtonIsAvailable(isEditing: true, isEditingAllowed: false))

    session.endEditing()
    #expect(session.isEditing == false)
    #expect(PodcastShowsViewPresentation.editButtonTitle(isEditing: session.isEditing) == "Edit")
  }

  @Test func dragDifferenceProducesExpectedIDOrder() {
    var session = PodcastShowsEditingSession()
    session.beginEditing(order: ["a", "b", "c", "d"])

    session.beginDrag("d")
    #expect(session.isDragging)
    session.dragEntered("b")

    // Entering a tile earlier in the sequence drops the dragged show in front of it.
    #expect(session.order == ["a", "d", "b", "c"])
    #expect(session.completeDrag() == ["a", "d", "b", "c"])
    #expect(session.isDragging == false)

    // Dragging forward lands after the entered tile.
    session.beginDrag("a")
    session.dragEntered("b")
    #expect(session.order == ["d", "b", "a", "c"])
    #expect(session.completeDrag() == ["d", "b", "a", "c"])
  }

  @Test func dragDifferenceAcrossRowsUsesLinearRowMajorOrder() {
    // Row-major over three adaptive columns: a b c / d e f. The durable value is one flat id
    // sequence, and the grid re-flows from it.
    var session = PodcastShowsEditingSession()
    session.beginEditing(order: ["a", "b", "c", "d", "e", "f"])

    session.beginDrag("e")
    session.dragEntered("b")
    let committed = session.completeDrag()

    #expect(committed == ["a", "e", "b", "c", "d", "f"])
    #expect(Self.rows(committed ?? [], columns: 3) == [["a", "e", "b"], ["c", "d", "f"]])
    // The same sequence re-flows into any column count without a second rule.
    #expect(
      Self.rows(committed ?? [], columns: 2) == [["a", "e"], ["b", "c"], ["d", "f"]])
  }

  @Test func dragNoOpDoesNotPersist() {
    var session = PodcastShowsEditingSession()
    session.beginEditing(order: ["a", "b", "c"])

    // Dropping a show onto itself.
    session.beginDrag("b")
    session.dragEntered("b")
    #expect(session.order == ["a", "b", "c"])
    #expect(session.completeDrag() == nil)

    // Wandering away and returning to the starting position.
    session.beginDrag("a")
    session.dragEntered("b")
    #expect(session.order == ["b", "a", "c"])
    session.dragEntered("b")
    #expect(session.order == ["a", "b", "c"])
    #expect(session.completeDrag() == nil)

    // A drag that was never started commits nothing either.
    #expect(session.completeDrag() == nil)
  }

  @Test func completedDragCommitsExactlyOnce() {
    var session = PodcastShowsEditingSession()
    session.beginEditing(order: ["a", "b", "c"])
    session.beginDrag("c")
    session.dragEntered("a")

    #expect(session.completeDrag() == ["c", "a", "b"])
    // A second `performDrop` for the same session must not re-commit the sequence.
    #expect(session.completeDrag() == nil)
  }

  @Test func editingRendersTheWorkingOrderWhileTheModelKeepsItsOwn() {
    let shows = [Self.show("a"), Self.show("b"), Self.show("c")]
    var session = PodcastShowsEditingSession()

    #expect(PodcastShowsViewPresentation.tiles(shows, in: session) == shows)

    session.beginEditing(order: ["a", "b", "c"])
    session.beginDrag("c")
    session.dragEntered("a")
    #expect(
      PodcastShowsViewPresentation.tiles(shows, in: session).map(\.serverItemId) == ["c", "a", "b"])

    // A show that arrived after the working order was seeded still renders, at the tail.
    let arrived = shows + [Self.show("d")]
    #expect(
      PodcastShowsViewPresentation.tiles(arrived, in: session).map(\.serverItemId)
        == ["c", "a", "b", "d"])
  }

  @Test func editingDisablesTileActivation() {
    var session = PodcastShowsEditingSession()
    #expect(PodcastShowsViewPresentation.tileIsSelectable(isEditing: session.isEditing))

    session.beginEditing(order: ["a", "b"])
    #expect(PodcastShowsViewPresentation.tileIsSelectable(isEditing: session.isEditing) == false)

    session.endEditing()
    #expect(PodcastShowsViewPresentation.tileIsSelectable(isEditing: session.isEditing))
  }

  @Test func editingDisablesContextMenu() {
    var session = PodcastShowsEditingSession()
    #expect(PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: session.isEditing))

    session.beginEditing(order: ["a", "b"])
    #expect(PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: session.isEditing) == false)

    session.endEditing()
    #expect(PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: session.isEditing))
  }

  @MainActor
  @Test func firstActualMoveSwitchesToCustom() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.shows.isEmpty == false }
    #expect(model.sortMode == .alphabetical)

    var session = PodcastShowsEditingSession()
    session.beginEditing(order: model.shows.map(\.serverItemId))

    // A drag that lands where it started is not a move: nothing is written, the mode stands.
    session.beginDrag("b")
    session.dragEntered("b")
    if let order = session.completeDrag() { await model.apply(order: order) }
    #expect(ordering.replacements.isEmpty)
    #expect(model.sortMode == .alphabetical)

    session.beginDrag("c")
    session.dragEntered("a")
    if let order = session.completeDrag() { await model.apply(order: order) }
    #expect(ordering.replacements == [["c", "a", "b"]])

    // The store's next observation is what actually flips the mode; the view never claims it.
    ordering.push(Self.snapshot(.custom, ["c", "a", "b"]))
    await waitUntil { model.sortMode == .custom }
    #expect(model.shows.map(\.serverItemId) == ["c", "a", "b"])
  }

  @MainActor
  @Test func saveFailureLeavesEditingAvailableAndShowsError() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.shows.isEmpty == false }

    var session = PodcastShowsEditingSession()
    session.beginEditing(order: model.shows.map(\.serverItemId))
    session.beginDrag("c")
    session.dragEntered("a")
    ordering.failNext()
    if let order = session.completeDrag() { await model.apply(order: order) }

    #expect(model.actionErrorMessage == PodcastShowsCopy.reorderFailed)
    // The page stays in edit mode and the durable order is untouched.
    #expect(session.isEditing)
    #expect(model.isEditingAllowed)
    #expect(model.shows.map(\.serverItemId) == ["a", "b", "c"])

    // Resyncing to the model, as the view does after a failed commit, restores durable truth.
    session.observe(order: model.shows.map(\.serverItemId))
    #expect(session.order == ["a", "b", "c"])

    model.dismissActionError()
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test func syncStartingWhileEditingEndsEditModeWithoutPersisting() async {
    let ordering = ShowsOrderingSpy()
    let library = Self.library(status: Self.settled)
    let model = Self.makeModel(ordering: ordering, library: library)
    ordering.push(Self.snapshot(.custom, ["a", "b", "c"]))
    await waitUntil { model.isEditingAllowed }

    var session = PodcastShowsEditingSession()
    session.beginEditing(order: model.shows.map(\.serverItemId))
    session.beginDrag("c")
    session.dragEntered("a")
    #expect(session.order == ["c", "a", "b"])

    library.pushSyncStatus(
      LibrarySyncStatus(isRunning: true, lastRunIncomplete: false, lastCompletedAt: Date()))
    await waitUntil { model.isEditingAllowed == false }
    session.syncGate(
      isEditingAllowed: model.isEditingAllowed, order: model.shows.map(\.serverItemId))

    #expect(session.isEditing == false)
    #expect(session.isDragging == false)
    #expect(session.order == ["a", "b", "c"])
    // The in-flight arrangement is discarded, not committed as a synthetic move.
    #expect(ordering.replacements.isEmpty)
    #expect(session.completeDrag() == nil)
    #expect(model.actionErrorMessage == nil)
  }

  // MARK: - Accessibility movement

  @Test func firstShowCannotMoveEarlier() {
    let moves = PodcastShowsViewPresentation.accessibilityMoveActions(
      isEditing: true, index: 0, count: 3)

    #expect(moves.contains(.earlier) == false)
    #expect(moves.contains(.later))
  }

  @Test func lastShowCannotMoveLater() {
    let moves = PodcastShowsViewPresentation.accessibilityMoveActions(
      isEditing: true, index: 2, count: 3)

    #expect(moves.contains(.later) == false)
    #expect(moves.contains(.earlier))
  }

  @Test func middleShowMovesExactlyOnePosition() {
    let moves = PodcastShowsViewPresentation.accessibilityMoveActions(
      isEditing: true, index: 1, count: 3)

    #expect(moves == [.earlier, .later])
    #expect(PodcastShowsViewPresentation.destination(for: .earlier, at: 1) == 0)
    #expect(PodcastShowsViewPresentation.destination(for: .later, at: 1) == 2)
  }

  @Test func positionValueUsesOneBasedIndexAndCount() {
    #expect(PodcastShowsViewPresentation.accessibilityPositionValue(index: 0, count: 5) == "1 of 5")
    #expect(PodcastShowsViewPresentation.accessibilityPositionValue(index: 4, count: 5) == "5 of 5")
  }

  @Test func accessibilityActionsExistOnlyWhileEditing() {
    #expect(
      PodcastShowsViewPresentation.accessibilityMoveActions(isEditing: false, index: 1, count: 3)
        .isEmpty)
    #expect(
      PodcastShowsViewPresentation.accessibilityMoveActions(isEditing: true, index: 1, count: 3)
        .isEmpty == false)
  }

  @MainActor
  @Test func accessibilityMoveCallsTheSamePersistencePathAsDrag() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.shows.isEmpty == false }

    // Move Later on the middle show commits through the same `PodcastShowsModel.move` ->
    // `apply(order:)` -> `PodcastShowOrdering.replaceCustomOrder` path as a drag.
    let index = 1
    let destination = PodcastShowsViewPresentation.destination(for: .later, at: index)
    await model.move(itemID: "b", to: destination)

    #expect(ordering.replacements == [["a", "c", "b"]])

    // The drag session commits the same sequence, so there is one persistence path, not two.
    var session = PodcastShowsEditingSession()
    session.beginEditing(order: ["a", "b", "c"])
    session.beginDrag("b")
    session.dragEntered("c")
    if let order = session.completeDrag() { await model.apply(order: order) }

    #expect(ordering.replacements.last == ["a", "c", "b"])
  }

  // MARK: - Mode display and confirmed reset

  @MainActor
  @Test func sortMenuReportsAlphabeticalWhenNoCustomOrder() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.shows.isEmpty == false }

    #expect(PodcastShowsViewPresentation.sortModeLabel(model.sortMode) == "Alphabetical")
    #expect(PodcastShowsViewPresentation.resetIsOffered(mode: model.sortMode) == false)
  }

  @MainActor
  @Test func sortMenuReportsCustomAfterMove() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.shows.isEmpty == false }

    await model.move(itemID: "c", to: 0)
    ordering.push(Self.snapshot(.custom, ["c", "a", "b"]))
    await waitUntil { model.sortMode == .custom }

    #expect(PodcastShowsViewPresentation.sortModeLabel(model.sortMode) == "Custom")
    #expect(PodcastShowsViewPresentation.resetIsOffered(mode: model.sortMode))
  }

  @Test func resetActionOnlyAppearsInCustomMode() {
    #expect(PodcastShowsViewPresentation.resetIsOffered(mode: .alphabetical) == false)
    #expect(PodcastShowsViewPresentation.resetIsOffered(mode: .custom))
  }

  @Test func resetRequiresConfirmation() {
    var confirmation = PodcastShowsResetConfirmation()
    // Being offered the row, or opening the menu that holds it, must not present the alert.
    #expect(confirmation.isPresented == false)

    confirmation.request()
    #expect(confirmation.isPresented)
  }

  @MainActor
  @Test func cancelResetPreservesCustomOrder() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.custom, ["c", "a", "b"]))
    await waitUntil { model.sortMode == .custom }

    var confirmation = PodcastShowsResetConfirmation()
    confirmation.request()
    confirmation.cancel()

    #expect(confirmation.isPresented == false)
    #expect(ordering.resets == 0)
    #expect(model.sortMode == .custom)
    #expect(model.shows.map(\.serverItemId) == ["c", "a", "b"])
  }

  @MainActor
  @Test func confirmResetRestoresAlphabeticalOrder() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.custom, ["c", "a", "b"]))
    await waitUntil { model.sortMode == .custom }

    var confirmation = PodcastShowsResetConfirmation()
    confirmation.request()
    confirmation.confirm()
    await model.resetToAlphabetical()

    #expect(confirmation.isPresented == false)
    #expect(ordering.resets == 1)
    #expect(model.actionErrorMessage == nil)

    // The store's next observation flips the mode, not the confirmation gate.
    ordering.push(Self.snapshot(.alphabetical, ["a", "b", "c"]))
    await waitUntil { model.sortMode == .alphabetical }
    #expect(model.shows.map(\.serverItemId) == ["a", "b", "c"])
  }

  @MainActor
  @Test func resetFailurePreservesCustomModeAndShowsError() async {
    let ordering = ShowsOrderingSpy()
    let model = Self.makeModel(ordering: ordering, library: Self.library(status: Self.settled))
    ordering.push(Self.snapshot(.custom, ["c", "a", "b"]))
    await waitUntil { model.sortMode == .custom }

    ordering.failNextReset()
    await model.resetToAlphabetical()

    #expect(model.actionErrorMessage == PodcastShowsCopy.resetFailed)
    #expect(model.sortMode == .custom)
    #expect(model.shows.map(\.serverItemId) == ["c", "a", "b"])

    model.dismissActionError()
    #expect(model.actionErrorMessage == nil)
  }

  // MARK: - Helpers

  private static func rows(_ ids: [String], columns: Int) -> [[String]] {
    stride(from: 0, to: ids.count, by: columns).map {
      Array(ids[$0..<min($0 + columns, ids.count)])
    }
  }

  private static let settled = LibrarySyncStatus(
    isRunning: false, lastRunIncomplete: false, lastCompletedAt: Date())

  private static func snapshot(
    _ mode: PodcastShowSortMode, _ ids: [String]
  ) -> PodcastShowsSnapshot {
    PodcastShowsSnapshot(mode: mode, shows: ids.map(Self.show))
  }

  @MainActor
  private static func makeModel(
    ordering: ShowsOrderingSpy, library: FakeLibraryReading
  ) -> PodcastShowsModel {
    PodcastShowsModel(ordering: ordering, library: library, sync: FakeSyncCoordinating())
  }

  /// Only the aggregate sync status matters here. It starts at `status` and stays pushable so the
  /// gate can close during a drag.
  private static func library(status: LibrarySyncStatus) -> FakeLibraryReading {
    let library = FakeLibraryReading()
    library.stubAggregateSyncStatus(status)
    return library
  }

}

/// A pushable ordering boundary that records what a completed drag committed. The real store is
/// covered in Core, so this only has to be observable.
private final class ShowsOrderingSpy: PodcastShowOrdering, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncStream<PodcastShowsSnapshot>.Continuation] = []
  private var recorded: [[String]] = []
  private var shouldFail = false
  private var resetCount = 0
  private var shouldFailReset = false

  var replacements: [[String]] { lock.withLock { recorded } }
  var resets: Int { lock.withLock { resetCount } }

  func failNext() { lock.withLock { shouldFail = true } }
  func failNextReset() { lock.withLock { shouldFailReset = true } }

  func observeShows() -> AsyncStream<PodcastShowsSnapshot> {
    AsyncStream { continuation in
      lock.withLock { continuations.append(continuation) }
    }
  }

  func push(_ snapshot: PodcastShowsSnapshot) {
    lock.withLock { continuations.last }?.yield(snapshot)
  }

  func replaceCustomOrder(itemIDs: [String]) async throws {
    try lock.withLock {
      if shouldFail {
        shouldFail = false
        throw ShowsOrderingSpyError.failed
      }
      recorded.append(itemIDs)
    }
  }

  func resetToAlphabetical() async throws {
    try lock.withLock {
      if shouldFailReset {
        shouldFailReset = false
        throw ShowsOrderingSpyError.failed
      }
      resetCount += 1
    }
  }
}

private enum ShowsOrderingSpyError: Error { case failed }
