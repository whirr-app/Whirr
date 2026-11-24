import Observation
import Persistence
import SyncEngine

/// Observable Settings state for this device's library selection. The durable projection is read
/// before discovery is requested, and observation remains active so a reconciliation or another
/// settings surface updates the rows without recreating this model.
@MainActor
@Observable
public final class LibrarySelectionSettingsModel {
  public enum LoadState: Sendable, Equatable {
    case loading
    case loaded
    case failed
  }

  public enum RefreshState: Sendable, Equatable {
    case idle
    case refreshing
    case reconciled
    case unavailable
  }

  public private(set) var loadState: LoadState = .loading
  public private(set) var refreshState: RefreshState = .idle
  public private(set) var snapshot: LibrarySelectionSnapshot?
  /// An error caused by this screen's most recent toggle. A server reconciliation failure is
  /// represented separately by `refreshState` so cached controls remain usable.
  public private(set) var toggleError: String?

  public var libraries: [SelectableLibrary] {
    snapshot?.libraries.filter(\.isAccessible) ?? []
  }

  public var includedAccessibleCount: Int {
    libraries.count(where: \.isIncluded)
  }

  public var selectionCount: String {
    SettingsCopy.librarySelectionCount(libraries: snapshot?.libraries ?? [])
  }

  /// The root Settings row's trailing value, absent until the durable snapshot has been read. The
  /// row must not quote loading copy in that slot: a long string there re-truncates the row's
  /// detail line for the frame before the count lands, which reads as the row twitching.
  public var selectionRowValue: String? {
    snapshot == nil ? nil : selectionCount
  }

  public var refreshMessage: String? {
    refreshState == .unavailable ? SettingsCopy.librarySelectionRefreshUnavailable : nil
  }

  private let reading: any LibrarySelectionReading
  private let writing: any LibrarySelectionWriting
  private let sync: any SyncCoordinating
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var hasLoaded = false

  public init(
    reading: any LibrarySelectionReading,
    writing: any LibrarySelectionWriting,
    sync: any SyncCoordinating
  ) {
    self.reading = reading
    self.writing = writing
    self.sync = sync
  }

  deinit { observationTask?.cancel() }

  /// Reads the cached selection, begins live observation, then asks the existing sync coordinator
  /// to reconcile discovery once. The refresh result is distinct from the durable
  /// load: an offline server does not erase rows that are still useful on this device.
  public func load() async {
    guard hasLoaded == false else { return }
    hasLoaded = true
    loadState = .loading
    startObserving()

    do {
      apply(try await reading.currentSelection())
      guard Task.isCancelled == false else { return }
      loadState = .loaded
    } catch {
      guard Task.isCancelled == false else { return }
      snapshot = nil
      loadState = .failed
      refreshState = .unavailable
      return
    }

    refreshState = .refreshing
    let result = await sync.refreshLibraryDiscovery()
    guard Task.isCancelled == false else { return }
    switch result {
    case .reconciled: refreshState = .reconciled
    case .unavailable: refreshState = .unavailable
    case .pending: refreshState = .idle
    }
  }

  /// Commits before asking SyncEngine for work. The observer is normally the source of the row's
  /// post-write value; the final-live-library failure leaves the existing included value untouched.
  public func setIncluded(_ included: Bool, libraryID: String) async {
    toggleError = nil
    do {
      try await writing.setIncluded(included, libraryID: libraryID)
      guard Task.isCancelled == false else { return }
      updateIncluded(included, libraryID: libraryID)
      if included {
        await sync.librarySelectionDidIncludeLibrary()
      }
    } catch LibrarySelectionStoreError.lastLiveLibrary {
      guard Task.isCancelled == false else { return }
      // The rejected write is atomically unchanged in Persistence. Mirror that invariant even if
      // this view received a stale observation just before the user tapped the switch.
      updateIncluded(true, libraryID: libraryID)
      toggleError = SettingsCopy.librarySelectionLastLibraryMessage
    } catch {
      // The durable observation still owns the committed state. Do not make an uncommitted
      // optimistic mutation visible after an arbitrary persistence failure.
      guard Task.isCancelled == false else { return }
    }
  }

  public func dismissToggleError() {
    toggleError = nil
  }

  private func startObserving() {
    guard observationTask == nil else { return }
    let stream = reading.observeSelection()
    observationTask = Task { [weak self] in
      for await snapshot in stream {
        guard Task.isCancelled == false, let self else { return }
        self.apply(snapshot)
        if self.loadState != .loaded {
          self.loadState = .loaded
        }
      }
    }
  }

  private func apply(_ snapshot: LibrarySelectionSnapshot) {
    if self.snapshot != snapshot {
      self.snapshot = snapshot
    }
  }

  private func updateIncluded(_ included: Bool, libraryID: String) {
    guard let snapshot else { return }
    let updated = snapshot.libraries.map { library in
      guard library.serverLibraryID == libraryID else { return library }
      return SelectableLibrary(
        serverLibraryID: library.serverLibraryID, name: library.name, mediaType: library.mediaType,
        isAccessible: library.isAccessible, isIncluded: included)
    }
    apply(LibrarySelectionSnapshot(mode: snapshot.mode, libraries: updated))
  }
}
