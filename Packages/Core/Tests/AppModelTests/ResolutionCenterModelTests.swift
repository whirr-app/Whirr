import Foundation
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

/// `ResolutionCenterModel` renders every open item from `ResolutionCenterAccess
/// .fetchOpenItems()` and forwards each kind's documented action, re-fetching afterward.
@MainActor
@Suite struct ResolutionCenterModelTests {

  // MARK: - Empty state

  @Test func emptyStateHasNoItemsAndDistinctCopy() async {
    let (model, _) = makeModel()

    await model.refresh()

    #expect(model.isEmpty)
    #expect(model.state == .empty)
    #expect(model.items.isEmpty)
    #expect(model.openCount == 0)
    #expect(ResolutionCenterCopy.emptyStateTitle != ResolutionCenterCopy.emptyStateMessage)
  }

  @Test func initialStateIsNotMistakenForEmptyState() {
    let (model, _) = makeModel()

    #expect(model.state == .loading)
    #expect(model.isEmpty == false)
  }

  @Test func fetchFailureIsNotPresentedAsEmptyState() async {
    let (model, access) = makeModel()
    struct Opaque: Error {}
    access.stubNextCall(throwing: Opaque())

    await model.refresh()

    #expect(model.state == .error)
    #expect(model.isEmpty == false)
    #expect(model.actionErrorMessage == nil)
  }

  @Test func retryAfterFetchFailureLoadsItems() async {
    let (model, access) = makeModel()
    struct Opaque: Error {}
    access.stubNextCall(throwing: Opaque())

    await model.refresh()
    #expect(model.isEmpty == false)
    #expect(model.state == .error)

    let item = ResolutionOpenItem(
      kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: Date())
    access.stubNextCall(throwing: nil)
    access.openItems = [item]

    await model.refresh()

    #expect(model.items == [item])
    #expect(model.isEmpty == false)
    #expect(model.state == .loaded)
    #expect(model.actionErrorMessage == nil)
  }

  @Test func failedResolutionActionKeepsIssueVisibleForRetry() async {
    let (model, access) = makeModel()
    let item = ResolutionOpenItem(
      kind: .progressConflict(conflictId: 7), itemTitle: "Book", detectedAt: Date())
    access.openItems = [item]
    await model.refresh()

    struct Opaque: Error {}
    access.stubNextCall(throwing: Opaque())

    await model.keepLocalProgress(conflictId: 7)

    #expect(model.items == [item])
    #expect(model.isEmpty == false)
    #expect(model.state == .loaded)
    #expect(model.actionErrorMessage == ResolutionCenterCopy.actionFailed)

    access.stubNextCall(throwing: nil)
    await model.keepLocalProgress(conflictId: 7)

    #expect(model.actionErrorMessage == nil)
    #expect(model.state == .empty)
    #expect(model.items.isEmpty)
  }

  @Test func noAPICallHappensOnConstruction() {
    let access = FakeResolutionCenterAccess()
    _ = ResolutionCenterModel(access: access)

    #expect(access.calls.isEmpty)
  }

  @Test func refreshPopulatesItemsAndBadgeCount() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(
        kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: Date()),
      ResolutionOpenItem(
        kind: .pausedAuthDownload(itemId: 2), itemTitle: "Book Two", detectedAt: nil),
    ]

    await model.refresh()

    #expect(model.items.count == 2)
    #expect(model.openCount == 2)
    #expect(model.isEmpty == false)
  }

  @Test func refreshUsesOneEnumerationForItemsAndBadge() async {
    let (model, access) = makeModel()
    let items = [
      ResolutionOpenItem(
        kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: Date()),
      ResolutionOpenItem(
        kind: .pausedAuthDownload(itemId: 2), itemTitle: "Book Two", detectedAt: nil),
    ]
    access.openItems = items

    await model.refresh()

    #expect(model.items == items)
    #expect(model.openCount == items.count)
    #expect(access.calls.filter { $0 == .fetchOpenItems }.count == 1)
    #expect(access.calls.filter { $0 == .openCount }.count == 0)
  }

  @Test func cancelledRefreshDoesNotPublishFetchedItems() async {
    let (model, access) = makeModel()
    let existingItems = [
      ResolutionOpenItem(
        kind: .progressConflict(conflictId: 1), itemTitle: "Existing Book", detectedAt: Date())
    ]
    access.openItems = existingItems
    await model.refresh()

    let fetchedItems = [
      ResolutionOpenItem(
        kind: .deadLetter(operationId: 2, reason: "validation"), itemTitle: "Fetched Book", detectedAt: nil)
    ]
    access.openItems = fetchedItems
    access.holdFetchItems()
    let refresh = Task { await model.refresh() }
    #expect(await waitUntil { access.calls.filter { $0 == .fetchOpenItems }.count == 2 })

    refresh.cancel()
    access.releaseFetchItems()
    await refresh.value

    #expect(model.items == existingItems)
    #expect(model.openCount == existingItems.count)
  }

  // MARK: - Progress conflict

  @Test func progressConflictActionsAreKeepLocalAndTakeServer() {
    #expect(
      ResolutionCenterCopy.actions(for: .progressConflict(conflictId: 1)) == [
        .keepLocalProgress, .takeServerProgress,
      ])
  }

  @Test func progressConflictCopyMentionsTheItemTitle() {
    #expect(ResolutionCenterCopy.progressConflictTitle(itemTitle: "Book One").contains("Book One"))
  }

  @Test func keepLocalProgressForwardsExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 7), itemTitle: "Book", detectedAt: Date())
    ]
    await model.refresh()

    await model.keepLocalProgress(conflictId: 7)

    #expect(access.calls.filter { $0 == .keepLocalProgress(conflictId: 7) }.count == 1)
    #expect(model.items.isEmpty, "the acted-upon conflict must be gone after refresh")
  }

  @Test func takeServerProgressForwardsExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 8), itemTitle: "Book", detectedAt: Date())
    ]
    await model.refresh()

    await model.takeServerProgress(conflictId: 8)

    #expect(access.calls.filter { $0 == .takeServerProgress(conflictId: 8) }.count == 1)
    #expect(model.items.isEmpty)
  }

  // MARK: - Progress conflict: bulk "use server for all"

  @Test func bulkTakeServerIsUnavailableBelowTwoProgressConflicts() async {
    let (model, _) = makeModel()
    #expect(model.canTakeServerForAllProgressConflicts == false)

    let (singleModel, singleAccess) = makeModel()
    singleAccess.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book", detectedAt: nil)
    ]
    await singleModel.refresh()
    #expect(singleModel.canTakeServerForAllProgressConflicts == false)
  }

  @Test func bulkTakeServerIsAvailableAtTwoOrMoreProgressConflictsButIgnoresOtherKinds() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: nil),
      ResolutionOpenItem(kind: .progressConflict(conflictId: 2), itemTitle: "Book Two", detectedAt: nil),
      ResolutionOpenItem(kind: .deadLetter(operationId: 3, reason: nil), itemTitle: "Book Three", detectedAt: nil),
    ]

    await model.refresh()

    #expect(model.canTakeServerForAllProgressConflicts)
  }

  @Test func bulkTakeServerForwardsToEveryOpenProgressConflictExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: nil),
      ResolutionOpenItem(kind: .progressConflict(conflictId: 2), itemTitle: "Book Two", detectedAt: nil),
    ]
    await model.refresh()

    await model.takeServerForAllProgressConflicts()

    // `FakeResolutionCenterAccess` has no bulk case of its own. The model's call lands on
    // `ResolutionCenterAccess`'s default extension, which fans out to the same per-conflict
    // `takeServerProgress` the single-row action uses, so that fan-out is what forwarding means.
    #expect(access.calls.filter { $0 == .takeServerProgress(conflictId: 1) }.count == 1)
    #expect(access.calls.filter { $0 == .takeServerProgress(conflictId: 2) }.count == 1)
    #expect(model.items.isEmpty, "every acted-upon conflict must be gone after refresh")
    #expect(model.isTakingServerForAllProgressConflicts == false, "cleared once the run finishes")
  }

  @Test func bulkTakeServerIsANoOpWhenNotAvailable() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book", detectedAt: nil)
    ]
    await model.refresh()
    #expect(model.canTakeServerForAllProgressConflicts == false)
    let callsBeforeAttempt = access.calls

    await model.takeServerForAllProgressConflicts()

    #expect(access.calls == callsBeforeAttempt, "guarded out before ever calling the access layer")
    #expect(model.items.count == 1, "the single conflict is untouched")
  }

  @Test func bulkTakeServerCannotDoubleFireWhileAlreadyInFlight() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: nil),
      ResolutionOpenItem(kind: .progressConflict(conflictId: 2), itemTitle: "Book Two", detectedAt: nil),
    ]
    await model.refresh()
    // The default bulk extension's own first step is `fetchOpenItems()`, so holding that call
    // parks the whole bulk run mid-flight without needing a dedicated bulk hold on the fake.
    access.holdFetchItems()

    let first = Task { await model.takeServerForAllProgressConflicts() }
    #expect(await waitUntil { model.isTakingServerForAllProgressConflicts })
    let fetchCallsWhileInFlight = access.calls.filter { $0 == .fetchOpenItems }.count

    await model.takeServerForAllProgressConflicts()
    #expect(
      access.calls.filter { $0 == .fetchOpenItems }.count == fetchCallsWhileInFlight,
      "the second call is guarded out before it ever reaches the access layer")

    access.releaseFetchItems()
    await first.value
    #expect(model.isTakingServerForAllProgressConflicts == false)
  }

  @Test func bulkTakeServerSurfacesAPartialFailureCountWithoutLosingWhatDidResolve() async {
    let access = FakeResolutionCenterAccess()
    access.openItems = [
      ResolutionOpenItem(kind: .progressConflict(conflictId: 1), itemTitle: "Book One", detectedAt: nil),
      ResolutionOpenItem(kind: .progressConflict(conflictId: 2), itemTitle: "Book Two", detectedAt: nil),
    ]
    access.stubbedBulkResult = BulkProgressConflictResolutionResult(resolvedCount: 1, failedCount: 1)
    let model = ResolutionCenterModel(access: access)
    await model.refresh()

    await model.takeServerForAllProgressConflicts()

    #expect(
      model.actionErrorMessage
        == ResolutionCenterCopy.takeServerForAllProgressConflictsPartialFailureMessage(failedCount: 1))
    #expect(model.isTakingServerForAllProgressConflicts == false)
  }

  // MARK: - Skew confirmation: keep-local overwrite warning + take-server alternative

  @Test func skewConfirmationActionsAreKeepLocalAndTakeServer() {
    #expect(
      ResolutionCenterCopy.actions(for: .skewConfirmation(operationId: 1, sessionId: 1)) == [
        .keepLocalSkew, .takeServerSkew,
      ])
  }

  @Test func requestingKeepLocalSkewStagesTheOverwriteWarningAndDoesNotActYet() async {
    let (model, access) = makeModel()

    model.requestKeepLocalSkew(operationId: 10, sessionId: 20, itemTitle: "Book Three")

    #expect(
      model.pendingSkewOverwriteConfirmation?.operationId == 10
        && model.pendingSkewOverwriteConfirmation?.sessionId == 20
        && model.pendingSkewOverwriteConfirmation?.itemTitle == "Book Three")
    #expect(
      ResolutionCenterCopy.keepLocalSkewOverwriteWarningTitle(itemTitle: "Book Three").contains(
        "Book Three"))
    #expect(access.calls.isEmpty, "staging must never act")
  }

  @Test func cancellingTheStagedSkewOverwriteLeavesEverythingIntact() async {
    let (model, access) = makeModel()
    model.requestKeepLocalSkew(operationId: 10, sessionId: 20, itemTitle: "Book Three")

    model.cancelPendingConfirmation()

    #expect(model.pendingSkewOverwriteConfirmation == nil)
    await model.confirmKeepLocalSkew()
    #expect(access.calls.isEmpty, "a cancelled confirmation must never forward the action")
  }

  @Test func confirmingTheStagedSkewOverwriteForwardsExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(
        kind: .skewConfirmation(operationId: 10, sessionId: 20), itemTitle: "Book Three", detectedAt: nil)
    ]
    await model.refresh()
    model.requestKeepLocalSkew(operationId: 10, sessionId: 20, itemTitle: "Book Three")

    await model.confirmKeepLocalSkew()

    #expect(access.calls.filter { $0 == .keepLocalSkew(operationId: 10, sessionId: 20) }.count == 1)
    #expect(model.pendingSkewOverwriteConfirmation == nil)
    #expect(model.items.isEmpty)
  }

  @Test func takeServerSkewIsTheUnstagedAlternativeAndForwardsExactlyOnce() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(
        kind: .skewConfirmation(operationId: 11, sessionId: 21), itemTitle: "Book Four", detectedAt: nil)
    ]
    await model.refresh()

    await model.takeServerSkew(operationId: 11, sessionId: 21)

    #expect(access.calls.filter { $0 == .takeServerSkew(operationId: 11, sessionId: 21) }.count == 1)
    #expect(model.pendingSkewOverwriteConfirmation == nil, "take-server never stages a confirmation")
    #expect(model.items.isEmpty)
  }

  // MARK: - Dead letter

  @Test func deadLetterActionsAreDiscardAndRefreshMetadata() {
    #expect(
      ResolutionCenterCopy.actions(for: .deadLetter(operationId: 1, reason: nil)) == [
        .discardDeadLetter, .refreshMetadata,
      ])
  }

  @Test func deadLetterMessageMentionsThePrivacySafeReasonWhenPresent() {
    #expect(ResolutionCenterCopy.deadLetterMessage(reason: "validation").contains("validation"))
    #expect(ResolutionCenterCopy.deadLetterMessage(reason: nil).isEmpty == false)
  }

  @Test func discardDeadLetterForwardsExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .deadLetter(operationId: 30, reason: "validation"), itemTitle: "Book", detectedAt: nil)
    ]
    await model.refresh()

    await model.discardDeadLetter(operationId: 30)

    #expect(access.calls.filter { $0 == .discardDeadLetter(operationId: 30) }.count == 1)
    #expect(model.items.isEmpty)
  }

  @Test func refreshMetadataDeadLetterForwardsExactlyOnceAndRefreshes() async {
    let (model, access) = makeModel()
    access.openItems = [
      ResolutionOpenItem(kind: .deadLetter(operationId: 31, reason: nil), itemTitle: "Book", detectedAt: nil)
    ]
    await model.refresh()

    await model.refreshMetadataDeadLetter(operationId: 31)

    #expect(access.calls.filter { $0 == .refreshMetadataDeadLetter(operationId: 31) }.count == 1)
    #expect(model.items.isEmpty)
  }

  // MARK: - Paused-auth download

  @Test func pausedAuthDownloadActionIsReAuthenticateOnly() {
    #expect(ResolutionCenterCopy.actions(for: .pausedAuthDownload(itemId: 1)) == [.reAuthenticate])
  }

  @Test func pausedAuthCopyMentionsTheItemTitle() {
    #expect(ResolutionCenterCopy.pausedAuthTitle(itemTitle: "Book Five").contains("Book Five"))
  }

  @Test func requestReAuthenticationForwardsExactlyOnce() async {
    let (model, access) = makeModel()

    await model.requestReAuthentication()

    #expect(access.calls == [.requestReAuthentication])
  }

  // MARK: - Every kind has distinct, non-empty title/message copy

  @Test func everyKindHasDistinctNonEmptyTitleAndMessageCopy() {
    let kinds: [ResolutionOpenItem.Kind] = [
      .progressConflict(conflictId: 1),
      .skewConfirmation(operationId: 1, sessionId: 1),
      .deadLetter(operationId: 1, reason: nil),
      .pausedAuthDownload(itemId: 1),
    ]
    let titles = kinds.map { ResolutionCenterCopy.title(for: $0, itemTitle: "X") }
    let messages = kinds.map { ResolutionCenterCopy.message(for: $0) }

    #expect(Set(titles).count == kinds.count, "every kind must have distinct title copy")
    #expect(messages.allSatisfy { $0.isEmpty == false })
  }

  // MARK: - Helpers

  private func makeModel() -> (ResolutionCenterModel, FakeResolutionCenterAccess) {
    let access = FakeResolutionCenterAccess()
    let model = ResolutionCenterModel(access: access)
    return (model, access)
  }
}

/// Delegates to a wrapped `FakeResolutionCenterAccess` except
/// `takeServerForAllProgressConflicts()`, which returns a canned result. The fake's stub applies
/// to every call alike, so this is the seam for a partial bulk failure.
