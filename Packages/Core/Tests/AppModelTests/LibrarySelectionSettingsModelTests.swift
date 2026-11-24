import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LibrarySelectionSettingsModelTests {
  @Test func cachedRowsLandBeforeTheDiscoveryRefreshAndObservationUpdatesThem() async {
    let reading = FakeLibrarySelectionAccess(snapshot: Self.snapshot())
    let sync = FakeSyncCoordinating(libraryDiscoveryResult: .reconciled)
    let model = LibrarySelectionSettingsModel(reading: reading, writing: reading, sync: sync)

    await model.load()

    #expect(model.loadState == .loaded)
    #expect(model.libraries == Self.snapshot().libraries)
    #expect(sync.discoveryRefreshCount == 1)

    let changed = LibrarySelectionSnapshot(
      mode: .selected,
      libraries: [Self.library(id: "books", name: "Books", included: false)])
    reading.emit(changed)

    #expect(await waitUntil { model.libraries == changed.libraries })
    #expect(model.includedAccessibleCount == 0)
  }

  @Test func disablingCommitsWithoutSyncIntentAndEnablingCommitsThenRequestsIt() async {
    let access = FakeLibrarySelectionAccess(snapshot: Self.snapshot())
    let sync = FakeSyncCoordinating(libraryDiscoveryResult: .reconciled)
    let model = LibrarySelectionSettingsModel(reading: access, writing: access, sync: sync)
    await model.load()

    await model.setIncluded(false, libraryID: "books")
    #expect(access.setCalls == [LibrarySelectionSetCall(included: false, libraryID: "books")])
    #expect(sync.inclusionIntentCount == 0)

    await model.setIncluded(true, libraryID: "books")
    #expect(
      access.setCalls == [
        LibrarySelectionSetCall(included: false, libraryID: "books"),
        LibrarySelectionSetCall(included: true, libraryID: "books"),
      ])
    #expect(sync.inclusionIntentCount == 1)
  }

  @Test func finalLiveLibraryFailureShowsExactCopyAndLeavesTheRowIncluded() async {
    let access = FakeLibrarySelectionAccess(snapshot: Self.snapshot())
    access.setResult = .failure(LibrarySelectionStoreError.lastLiveLibrary)
    let model = LibrarySelectionSettingsModel(
      reading: access, writing: access,
      sync: FakeSyncCoordinating(libraryDiscoveryResult: .reconciled))
    await model.load()

    await model.setIncluded(false, libraryID: "books")

    #expect(model.toggleError == SettingsCopy.librarySelectionLastLibraryMessage)
    #expect(model.libraries.first?.isIncluded == true)
  }

  @Test func unavailableDiscoveryKeepsCachedRowsAndShowsUnavailableState() async {
    let cached = Self.snapshot()
    let model = LibrarySelectionSettingsModel(
      reading: FakeLibrarySelectionAccess(snapshot: cached),
      writing: FakeLibrarySelectionAccess(snapshot: cached),
      sync: FakeSyncCoordinating(libraryDiscoveryResult: .unavailable))

    await model.load()

    #expect(model.loadState == .loaded)
    #expect(model.refreshState == .unavailable)
    #expect(model.libraries == cached.libraries)
    #expect(model.refreshMessage == SettingsCopy.librarySelectionRefreshUnavailable)
  }

  @Test func selectedCountUsesAccessibleReconciledRowsOnly() {
    let rows = [
      Self.library(id: "books", name: "Books", included: true),
      Self.library(id: "podcasts", name: "Podcasts", included: false),
      SelectableLibrary(
        serverLibraryID: "removed", name: "Removed", mediaType: "book", isAccessible: false,
        isIncluded: true),
    ]

    #expect(SettingsCopy.librarySelectionCount(libraries: rows) == "1 of 2")
  }

  @Test func rowValueIsAbsentUntilTheSnapshotIsReadAndItsPlaceholderMatchesTheCountShape() async {
    let access = FakeLibrarySelectionAccess(snapshot: Self.snapshot())
    let model = LibrarySelectionSettingsModel(
      reading: access, writing: access,
      sync: FakeSyncCoordinating(libraryDiscoveryResult: .reconciled))

    #expect(model.selectionRowValue == nil)

    await model.load()

    #expect(model.selectionRowValue == "1 of 1")
    #expect(SettingsCopy.librarySelectionCountPlaceholder == "0 of 0")
  }

  private static func snapshot() -> LibrarySelectionSnapshot {
    LibrarySelectionSnapshot(
      mode: .selected,
      libraries: [library(id: "books", name: "Books", included: true)])
  }

  private static func library(id: String, name: String, included: Bool) -> SelectableLibrary {
    SelectableLibrary(
      serverLibraryID: id, name: name, mediaType: "book", isAccessible: true, isIncluded: included)
  }
}

private final class FakeLibrarySelectionAccess:
  LibrarySelectionReading, LibrarySelectionWriting, @unchecked Sendable
{
  private var continuation: AsyncStream<LibrarySelectionSnapshot>.Continuation?
  var snapshot: LibrarySelectionSnapshot
  var setResult: Result<Void, Error> = .success(())
  private(set) var setCalls: [LibrarySelectionSetCall] = []

  init(snapshot: LibrarySelectionSnapshot) {
    self.snapshot = snapshot
  }

  func currentSelection() async throws -> LibrarySelectionSnapshot { snapshot }

  func observeSelection() -> AsyncStream<LibrarySelectionSnapshot> {
    AsyncStream { continuation in
      self.continuation = continuation
      continuation.yield(snapshot)
    }
  }

  func completeOnboarding(includedIDs: Set<String>) async throws {}

  func setIncluded(_ included: Bool, libraryID: String) async throws {
    setCalls.append(LibrarySelectionSetCall(included: included, libraryID: libraryID))
    try setResult.get()
  }

  func emit(_ snapshot: LibrarySelectionSnapshot) {
    self.snapshot = snapshot
    continuation?.yield(snapshot)
  }
}

private struct LibrarySelectionSetCall: Equatable {
  let included: Bool
  let libraryID: String
}
