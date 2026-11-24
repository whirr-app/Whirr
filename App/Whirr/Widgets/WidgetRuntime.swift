import ABSApi
import AppModel
import Foundation
import Persistence
import WidgetKit
import WidgetProtocol

/// The process-lifetime owner of the widget publisher, as `WatchCompanionRuntime` is for the
/// Watch, and independent of it: the publisher runs whether or not a Watch is paired.
///
/// `RootComposition` binds it for an authenticated graph; logout unbinds through
/// `PlaybackLogoutPreflight`. Rebinding for another account skips the signed-out write, so the new
/// snapshot replaces the old directly.
@MainActor
final class WidgetRuntime {
  /// The controls read the same snapshot (the play or pause toggle's value, the skip-back
  /// interval) and are reloaded separately from widget timelines.
  static let shared = WidgetRuntime(
    store: { WidgetFileStore.production(applicationSupportDirectory: $0) },
    reloadTimelines: {
      WidgetCenter.shared.reloadAllTimelines()
      ControlCenter.shared.reloadAllControls()
    },
    configuredSmartLists: WidgetRuntime.currentSmartListConfigurations)

  /// The list each placed smart list widget shows; `nil` for one not yet configured.
  /// `WidgetInfo` is not `Sendable`, so it is reduced to ids inside the callback.
  nonisolated static func currentSmartListConfigurations() async -> [Int64?] {
    await withCheckedContinuation { continuation in
      WidgetCenter.shared.getCurrentConfigurations { result in
        let infos = (try? result.get()) ?? []
        let ids: [Int64?] = infos.compactMap { info in
          guard info.kind == SmartListWidgetIntent.widgetKind else { return nil }
          return .some(
            info.widgetConfigurationIntent(of: SmartListWidgetIntent.self)?.list
              .flatMap { WidgetSmartListID.parse($0.id) })
        }
        continuation.resume(returning: ids)
      }
    }
  }

  typealias StoreFactory = @MainActor (URL?) -> WidgetFileStore

  private let makeStore: StoreFactory
  private let reloadTimelines: WidgetSnapshotPublisher.ReloadTimelines
  private let configuredSmartLists: WidgetSmartListFeed.ConfiguredLists
  private(set) var publisher: WidgetSnapshotPublisher?
  private var store: WidgetFileStore?

  init(
    store: @escaping StoreFactory, reloadTimelines: @escaping WidgetSnapshotPublisher.ReloadTimelines,
    configuredSmartLists: @escaping WidgetSmartListFeed.ConfiguredLists = { [] }
  ) {
    makeStore = store
    self.reloadTimelines = reloadTimelines
    self.configuredSmartLists = configuredSmartLists
  }

  /// `applicationSupportDirectory` is the composition's own: a test graph gets a store under its
  /// temporary directory rather than the real App Group container.
  func bind(
    identity: AccountIdentity, dependencies: AppDependencies, playback: PlaybackModel,
    artwork: (any ArtworkServing)?, smartLists: SmartListServices? = nil,
    applicationSupportDirectory: URL?
  ) -> WidgetSnapshotPublisher? {
    unbind(publishSignedOut: false)
    let store = makeStore(applicationSupportDirectory)
    self.store = store
    guard
      let publisher = try? WidgetSnapshotPublisher(
        identity: identity, dependencies: dependencies, playback: playback, artwork: artwork,
        store: store, smartLists: smartLists.map(SmartListServicesWidgetSource.init(services:)),
        configuredSmartLists: configuredSmartLists, reloadTimelines: reloadTimelines)
    else {
      unbind(applicationSupportDirectory: applicationSupportDirectory)
      return nil
    }
    self.publisher = publisher
    publisher.start()
    return publisher
  }

  /// A widget row's token, resolved for the bound account only: with no binding, or a map
  /// written for another account, nothing resolves.
  func selection(for token: String) -> CompanionSelection? {
    guard let publisher, let map = store?.readTokenMap(), map.belongs(to: publisher.stamp) else {
      return nil
    }
    return map.selection(for: token)
  }

  /// A smart list widget row's token, resolved as `selection(for:)` resolves a shelf row's.
  func listSelection(for token: String) -> WidgetTokenMap.ListSelection? {
    guard let publisher, let map = store?.readTokenMap(), map.belongs(to: publisher.stamp) else {
      return nil
    }
    return map.listSelection(for: token)
  }

  /// The name of a list the bound publisher last published; `nil` for any other id.
  func smartListName(id: Int64) -> String? {
    publisher?.publishedSmartListName(id: id)
  }

  /// Stops the publisher and, by default, leaves the widgets signed out: a signed-out snapshot,
  /// no covers, no token map, and reloaded timelines.
  func unbind(publishSignedOut: Bool = true, applicationSupportDirectory: URL? = nil) {
    publisher?.stop()
    publisher = nil
    guard publishSignedOut else { return }
    let store = self.store ?? makeStore(applicationSupportDirectory)
    self.store = nil
    store.removeCoversAndTokenMap()
    // Already signed out on disk: nothing to write and nothing for the extension to redraw.
    if let existing = store.readSnapshot(), existing.accountStamp == nil { return }
    let signedOut = WidgetSnapshot.signedOut(generatedAt: Date())
    guard let data = try? WidgetSnapshotCodec.encode(signedOut) else { return }
    try? store.writeSnapshot(data)
    reloadTimelines()
  }
}
