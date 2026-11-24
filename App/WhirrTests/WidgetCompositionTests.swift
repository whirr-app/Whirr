import AppModel
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing
import WidgetProtocol

@testable import Whirr

/// The widget runtime's composition boundaries. Each test injects its own runtime over a temporary
/// application-support directory, which also stands in for the App Group container.
@MainActor
@Suite("Widget composition", .serialized)
struct WidgetCompositionTests {
  @Test("an authenticated graph binds the widgets with no Watch runtime composed")
  func widgetsBindIndependentlyOfTheWatch() throws {
    let harness = try Harness()
    let composition = try harness.compose(mode: .runtime, database: Self.authenticatedDatabase())

    #expect(composition.watchCataloguePublisher == nil)
    let publisher = try #require(composition.widgetSnapshotPublisher)
    #expect(harness.runtime.publisher === publisher)
  }

  @Test("logout signs the widgets out, and the setup graph that follows leaves them signed out")
  func logoutSignsTheWidgetsOut() async throws {
    let harness = try Harness()
    let database = try Self.authenticatedDatabase()
    let signedIn = try harness.compose(mode: .runtime, database: database)
    #expect(signedIn.widgetSnapshotPublisher != nil)

    await signedIn.logoutPreflight.prepareForLogout()

    #expect(harness.runtime.publisher == nil)
    #expect(harness.store.readSnapshot()?.accountStamp == nil)
    #expect(harness.store.readSnapshot() != nil, "a signed-out file, not a missing one")
    let reloads = harness.reloads.value

    try AccountDAO(database: database).delete()
    let setup = try harness.compose(mode: .automatic, database: database)

    #expect(setup.environment.composition == .setup)
    #expect(setup.widgetSnapshotPublisher == nil)
    #expect(harness.reloads.value == reloads, "already signed out: nothing to redraw")
  }

  @Test("a graph composed without a widget runtime binds nothing")
  func compositionCanOmitTheWidgetRuntime() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-widget-composition-\(UUID().uuidString)", isDirectory: true)
    let composition = RootComposition(
      hardware: PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()),
      mode: .runtime, database: try Self.authenticatedDatabase(),
      applicationSupportDirectory: directory, watchCompanionRuntime: nil)

    #expect(composition.widgetSnapshotPublisher == nil)
  }

  private static func authenticatedDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "widget-composition",
        serverBaseURL: "https://widget-composition.invalid",
        serverUserId: "widget-composition-user",
        serverVersion: "2.35.1",
        defaultLibraryId: "widget-composition-library"))
    return database
  }
}

@MainActor
private final class ReloadCounter {
  var value = 0
}

@MainActor
private final class Harness {
  let directory: URL
  let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
  let reloads = ReloadCounter()
  let runtime: WidgetRuntime

  var store: WidgetFileStore { WidgetFileStore.production(applicationSupportDirectory: directory) }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "whirr-widget-composition-\(UUID().uuidString)", isDirectory: true)
    let reloads = reloads
    runtime = WidgetRuntime(
      store: { WidgetFileStore.production(applicationSupportDirectory: $0) },
      reloadTimelines: { reloads.value += 1 })
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func compose(mode: AppEnvironment.Mode, database: AppDatabase) throws -> RootComposition {
    RootComposition(
      hardware: hardware, mode: mode, database: database, applicationSupportDirectory: directory,
      watchCompanionRuntime: nil, widgetRuntime: runtime)
  }
}
