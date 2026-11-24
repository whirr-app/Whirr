import Foundation
import UIKit

/// Keeps every smart list's first rows current enough for the widget, at a cost that does not
/// grow with the number of lists:
///
/// - lists a placed widget shows (at most `maxObservedLists`) are observed live;
/// - every other list is read once at start, whenever the lists change, when native
///   subscriptions are switched, and when the app enters or leaves the foreground, so a widget
///   configured while the app is closed still has rows to draw.
///
/// Which lists widgets show comes from an injected closure over WidgetKit's current
/// configurations; an unconfigured widget (`nil`) shows the first list.
@MainActor
final class WidgetSmartListFeed {
  /// The most lists observed live; a fifth configured list is read like an unconfigured one.
  nonisolated static let maxObservedLists = 4

  typealias ConfiguredLists = @Sendable () async -> [Int64?]

  private let source: any WidgetSmartListSource
  private let configuredLists: ConfiguredLists
  private let notificationCenter: NotificationCenter
  private let onChange: @MainActor () -> Void

  private(set) var lists: [WidgetSmartListName] = []
  private(set) var contents: [Int64: WidgetSmartListContent] = [:]
  /// The lists placed widgets show, resolved against `lists`.
  private(set) var shownListIDs: Set<Int64> = []

  private var started = false
  private var epoch: UInt64 = 0
  private var nativeEnabled = false
  private var configured: [Int64?] = []
  private var listsTask: Task<Void, Never>?
  private var configurationTask: Task<Void, Never>?
  private var fetchTask: Task<Void, Never>?
  private var observers: [Int64: Task<Void, Never>] = [:]
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    source: any WidgetSmartListSource, configuredLists: @escaping ConfiguredLists,
    notificationCenter: NotificationCenter = .default, onChange: @escaping @MainActor () -> Void
  ) {
    self.source = source
    self.configuredLists = configuredLists
    self.notificationCenter = notificationCenter
    self.onChange = onChange
  }

  /// Starts on the first call; later calls pass on a change to native subscriptions.
  func start(nativeEnabled: Bool) {
    guard !started else {
      setNativeEnabled(nativeEnabled)
      return
    }
    started = true
    epoch &+= 1
    self.nativeEnabled = nativeEnabled
    let epoch = epoch
    let stream = source.observeLists()
    listsTask = Task { [weak self] in
      for await lists in stream {
        guard let self, self.started, self.epoch == epoch else { return }
        self.receive(lists: lists)
      }
    }
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
      lifecycleObservers.append(
        notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.refresh() }
        })
    }
    readConfigurations()
  }

  func stop() {
    started = false
    epoch &+= 1
    listsTask?.cancel()
    listsTask = nil
    configurationTask?.cancel()
    configurationTask = nil
    fetchTask?.cancel()
    fetchTask = nil
    for task in observers.values { task.cancel() }
    observers = [:]
    for observer in lifecycleObservers { notificationCenter.removeObserver(observer) }
    lifecycleObservers = []
  }

  /// Native subscriptions switched: every list's content changes shape, so all of it is re-read.
  func setNativeEnabled(_ enabled: Bool) {
    guard started, enabled != nativeEnabled else { return }
    nativeEnabled = enabled
    for task in observers.values { task.cancel() }
    observers = [:]
    contents = [:]
    reconcile()
  }

  /// Re-reads widget configurations and every unobserved list.
  func refresh() {
    guard started else { return }
    readConfigurations()
  }

  private func receive(lists: [WidgetSmartListName]) {
    self.lists = lists
    let ids = Set(lists.map(\.id))
    contents = contents.filter { ids.contains($0.key) }
    reconcile()
    onChange()
  }

  private func readConfigurations() {
    configurationTask?.cancel()
    let epoch = epoch
    let configuredLists = configuredLists
    configurationTask = Task { [weak self] in
      let configured = await configuredLists()
      guard !Task.isCancelled, let self, self.started, self.epoch == epoch else { return }
      self.configured = configured
      self.reconcile()
      self.onChange()
    }
  }

  /// Observes the shown lists, stops observing the rest, and reads every unobserved list once.
  private func reconcile() {
    let ids = Set(lists.map(\.id))
    var shown: [Int64] = []
    for entry in configured {
      guard let id = entry ?? lists.first?.id, ids.contains(id), !shown.contains(id) else { continue }
      shown.append(id)
    }
    shownListIDs = Set(shown)
    let observed = Set(shown.prefix(Self.maxObservedLists))
    for (id, task) in observers where !observed.contains(id) {
      task.cancel()
      observers[id] = nil
    }
    for id in observed where observers[id] == nil {
      observers[id] = observe(listID: id)
    }
    fetch(lists.map(\.id).filter { !observed.contains($0) })
  }

  private func observe(listID: Int64) -> Task<Void, Never> {
    let epoch = epoch
    let stream = source.observeContent(listID: listID, nativeEnabled: nativeEnabled)
    return Task { [weak self] in
      for await content in stream {
        // A value already delivered when the list stopped being observed (deleted, or no
        // longer shown) must not write it back.
        guard !Task.isCancelled, let self, self.started, self.epoch == epoch else { return }
        self.contents[listID] = content
        self.onChange()
      }
    }
  }

  /// One read per list, in order; a newer request replaces one still running.
  private func fetch(_ ids: [Int64]) {
    fetchTask?.cancel()
    guard !ids.isEmpty else { return }
    let epoch = epoch
    let source = source
    let nativeEnabled = nativeEnabled
    fetchTask = Task { [weak self] in
      var read: [Int64: WidgetSmartListContent] = [:]
      for id in ids {
        guard !Task.isCancelled else { return }
        if let content = await source.fetchContent(listID: id, nativeEnabled: nativeEnabled) {
          read[id] = content
        }
      }
      guard !Task.isCancelled, let self, self.started, self.epoch == epoch else { return }
      let current = Set(self.lists.map(\.id))
      for id in ids where current.contains(id) && self.observers[id] == nil {
        // A failed read keeps what the list had; a list never read draws as empty rather than
        // holding back every other list's publication.
        if let content = read[id] {
          self.contents[id] = content
        } else if self.contents[id] == nil {
          self.contents[id] = WidgetSmartListContent(episodes: [], matchCount: nil)
        }
      }
      self.onChange()
    }
  }
}
