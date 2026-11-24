import Foundation
import Observation
import Persistence

public enum SmartListEditorCopy {
  public static let listLimitReached = SmartListsCopy.listLimitReached
  public static let saveFailed = "Couldn't save the smart list. Try again."
  public static let loadFailed = "Couldn't open the smart list. Try again."
}

public enum SmartListEditorError: Error, Sendable, Equatable {
  case invalidName
  case invalidRules(SmartListRulesError)
  case listLimitReached
  case listNotFound
  case saveFailed

  public var message: String {
    switch self {
    case .listLimitReached: SmartListEditorCopy.listLimitReached
    case .listNotFound: SmartListEditorCopy.loadFailed
    case .invalidName, .invalidRules, .saveFailed: SmartListEditorCopy.saveFailed
    }
  }
}

/// A starting point offered by the New sheet (plan: "App").
public enum SmartListTemplate: Sendable, CaseIterable {
  case blank
  case newEpisodesThisWeek
  case shortEpisodes
  case downloaded

  public var name: String {
    switch self {
    case .blank: ""
    case .newEpisodesThisWeek: "New episodes this week"
    case .shortEpisodes: "Short episodes"
    case .downloaded: "Downloaded"
    }
  }

  public var rules: SmartListRules {
    switch self {
    case .blank: .default
    case .newEpisodesThisWeek: SmartListRules(releaseWindow: .week)
    case .shortEpisodes: .shortEpisodes
    case .downloaded: .downloaded
    }
  }
}

public enum SmartListNameValidation: Sendable, Equatable {
  case valid
  case empty
  case tooLong
}

/// The create and edit sheet's draft: name, rules, shows and auto-download; the live match count;
/// the show picker; and the save.
///
/// Saving writes through `SmartListStore`, then starts save-time expansion of this list's
/// Audiobookshelf shows without waiting for it ("Updating shows…" follows `isUpdatingShows`).
/// Hidden episodes are not touched: they are pruned when finished or gone, not when a
/// rule changes, so an edit that is undone brings them back as they were.
@MainActor
@Observable
public final class SmartListEditorModel {
  public enum Mode: Sendable, Equatable {
    case create
    case edit(listID: Int64)
  }

  public static let defaultDebounce: Duration = .milliseconds(300)

  public let mode: Mode
  public var name: String
  public var rules: SmartListRules {
    didSet {
      // A list showing one download state cannot auto-download.
      if rules.autoDownload, canAutoDownload == false { rules.autoDownload = false }
      if rules != oldValue { draftChanged() }
    }
  }

  public private(set) var isLoading: Bool
  public private(set) var isSaving = false
  public private(set) var loadError: SmartListEditorError?
  public private(set) var saveError: SmartListEditorError?
  /// Nil while it is being worked out, or when the rules are invalid.
  public private(set) var matchCount: Int?
  public private(set) var isUpdatingShows = false
  public private(set) var pickerShows: [SmartListPickerShow] = []
  public private(set) var sources: SmartListSourceState?
  /// The list once it has been written; a second save edits it.
  public private(set) var savedList: SmartList?

  /// Called after each successful save, so the collection and list screens can reload.
  @ObservationIgnored public var onSaved: (@MainActor (SmartList) -> Void)?

  private let services: SmartListServices
  private let debounce: Duration
  private var picker = SmartListShowPicker()
  @ObservationIgnored private var reading: SmartListEpisodesReading?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var countTask: Task<Void, Never>?
  @ObservationIgnored private var updatingTask: Task<Void, Never>?
  @ObservationIgnored private var updatingKey: [Int64]?
  @ObservationIgnored private(set) var expansionTask: Task<Void, Never>?

  public init(
    services: SmartListServices, mode: Mode = .create, template: SmartListTemplate = .blank,
    debounce: Duration = SmartListEditorModel.defaultDebounce
  ) {
    self.services = services
    self.mode = mode
    self.debounce = debounce
    name = template.name
    rules = template.rules
    isLoading = mode != .create

    let sourceStream = services.observeSources()
    tasks.append(
      Task { [weak self] in
        for await sources in sourceStream {
          guard let self else { return }
          self.apply(sources)
        }
      })
    let catalogStream = services.showCatalog.observeShows()
    tasks.append(
      Task { [weak self] in
        for await shows in catalogStream {
          guard let self else { return }
          self.picker.catalog = shows
          await self.refreshTwins()
        }
      })
  }

  deinit {
    for task in tasks { task.cancel() }
    countTask?.cancel()
    updatingTask?.cancel()
  }

  // MARK: - Validation

  public var nameValidation: SmartListNameValidation {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .empty }
    return SmartListRules.normalizedName(name) == nil ? .tooLong : .valid
  }

  public var rulesError: SmartListRulesError? {
    do {
      try rules.validate()
      return nil
    } catch {
      return error as? SmartListRulesError
    }
  }

  public var canSave: Bool {
    nameValidation == .valid && rulesError == nil && isSaving == false && isLoading == false
      && loadError == nil
  }

  // MARK: - Auto-download

  /// Auto-download keeps the list's top episodes downloaded, which only holds together while the
  /// list shows both download states: a Not downloaded list would drop each episode as it
  /// finished downloading, then fetch it again. Choosing one state turns it off.
  public var canAutoDownload: Bool { rules.includeDownloaded && rules.includeNotDownloaded }

  /// Turning it on keeps the limit already chosen, ten for a new list.
  public var autoDownload: Bool {
    get { rules.autoDownload }
    set { rules.autoDownload = newValue && canAutoDownload }
  }

  public var autoDownloadLimit: SmartListAutoDownloadLimit {
    get { rules.autoDownloadLimit }
    set { rules.autoDownloadLimit = newValue }
  }

  // MARK: - Shows

  public func role(for ref: SmartListShowRef) -> SmartListShowRole? {
    picker.role(for: ref)
  }

  /// Sets or clears a show's role. A show followed natively and present on the server is one row;
  /// choosing it chooses both copies.
  public func setRole(_ role: SmartListShowRole?, for ref: SmartListShowRef) {
    picker.setRole(role, for: ref)
    draftChanged()
  }

  /// What a save would write for the current scope.
  public var selections: [SmartListShowSelection] {
    picker.selections(for: rules.showScope)
  }

  // MARK: - Loading

  /// Reads the list being edited. A create sheet has nothing to load.
  public func load() async {
    guard case .edit(let listID) = mode else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      guard let list = try await services.store.list(id: listID) else {
        loadError = .listNotFound
        return
      }
      let stored = try await services.store.shows(listID: listID)
      name = list.name
      rules = list.rules
      picker.load(stored: stored)
      loadError = nil
      draftChanged()
      restartUpdating()
    } catch {
      loadError = .listNotFound
    }
  }

  private func apply(_ sources: SmartListSourceState) {
    self.sources = sources
    picker.sources = sources
    // Recompute now: the twin refresh below is asynchronous, and until it runs the picker would
    // still show the shows of the previous sources.
    pickerShows = picker.items
    reading = services.makeReading(sources.nativeEnabled)
    Task { await refreshTwins() }
    restartUpdating()
  }

  private func refreshTwins() async {
    if let reading, sources?.accountID != nil {
      picker.twinKeys = (try? await reading.serverShowKeysWithFollowedNativeTwin()) ?? []
    } else {
      picker.twinKeys = []
    }
    draftChanged()
  }

  private func draftChanged() {
    pickerShows = picker.items
    scheduleCount()
  }

  // MARK: - Live match count

  private func scheduleCount() {
    countTask?.cancel()
    guard let reading, rulesError == nil else {
      matchCount = nil
      return
    }
    let rules = rules
    let shows = selections
    let listID = persistedListID
    let debounce = debounce
    countTask = Task { [weak self] in
      try? await Task.sleep(for: debounce)
      guard Task.isCancelled == false else { return }
      let count = try? await reading.matchCount(rules: rules, shows: shows, listID: listID)
      guard Task.isCancelled == false, let self else { return }
      self.matchCount = count
    }
  }

  // MARK: - Updating shows

  private var persistedListID: Int64? {
    if let savedList { return savedList.id }
    if case .edit(let listID) = mode { return listID }
    return nil
  }

  private func restartUpdating() {
    guard let listID = persistedListID, let accountID = sources?.accountID else {
      updatingTask?.cancel()
      updatingKey = nil
      isUpdatingShows = false
      return
    }
    guard updatingKey != [listID, accountID] else { return }
    updatingKey = [listID, accountID]
    updatingTask?.cancel()
    let stream = services.expansionReading.observeIsUpdating(listID: listID, accountID: accountID)
    updatingTask = Task { [weak self] in
      for await updating in stream {
        guard let self else { return }
        self.isUpdatingShows = updating
      }
    }
  }

  // MARK: - Saving

  /// Writes the draft: a new list, or the one being edited. Returns the list, or nil with
  /// `saveError` set. The 50-list cap is `listLimitReached`.
  @discardableResult
  public func save() async -> SmartList? {
    guard isSaving == false else { return nil }
    guard nameValidation == .valid else {
      saveError = .invalidName
      return nil
    }
    if let error = rulesError {
      saveError = .invalidRules(error)
      return nil
    }
    isSaving = true
    defer { isSaving = false }
    let shows = selections
    do {
      let list: SmartList
      if let id = persistedListID {
        try await services.store.save(id: id, name: name, rules: rules, shows: shows)
        guard let updated = try await services.store.list(id: id) else {
          saveError = .listNotFound
          return nil
        }
        list = updated
      } else {
        list = try await services.store.create(name: name, rules: rules, shows: shows)
      }
      savedList = list
      saveError = nil
      restartUpdating()
      if sources?.accountID != nil {
        expansionTask = services.startExpansion(listID: list.id)
      }
      onSaved?(list)
      return list
    } catch SmartListStoreError.listLimitReached {
      saveError = .listLimitReached
    } catch SmartListStoreError.invalidName {
      saveError = .invalidName
    } catch SmartListStoreError.invalidRules(let rulesError) {
      saveError = .invalidRules(rulesError)
    } catch SmartListStoreError.listNotFound {
      saveError = .listNotFound
    } catch {
      saveError = .saveFailed
    }
    return nil
  }
}
