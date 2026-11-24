import ABSApi
import CoreSupport
import Foundation
import OSLog
import Persistence
import SyncEngine

/// Brings every item's saved palette up to date in the foreground, so a first-opened detail page
/// paints its colour on the first frame (`CoverPaletteService.prepare` answers from the row).
///
/// Independent of cover transfers: extraction reads cached thumbnail bytes only, so the cover
/// pass's network and preference gates don't apply; an item not on disk waits for a later trigger.
/// Each run recomputes candidates from the rows, so one stopped by backgrounding just resumes.
@MainActor
final class CoverPaletteBackfill {
  nonisolated struct Item: Sendable, Equatable {
    let itemID: String
    /// The home card key, the palette source every surface extracts from (`CoverPaletteSource`).
    /// Record identity is variant-free, so the row written from it is the one every surface reads.
    let key: ArtworkKey
  }

  private static let logger = CoreLogging.logger(category: "PaletteBackfill")

  private let items: @Sendable () async -> [Item]
  /// Selects the candidates: items whose row is missing, was written for another identity, or
  /// predates the page-evidence columns.
  private let service: CoverPaletteService
  private let save: @Sendable (Item) async throws -> Void
  private let lifecycle: any AppLifecycle
  private let conditions: any NetworkConditions
  private let isThermallyConstrained: @Sendable () -> Bool
  private var runTask: Task<Void, Never>?
  private var rerunRequested = false
  private var observers: [Task<Void, Never>] = []

  init(
    items: @escaping @Sendable () async -> [Item],
    service: CoverPaletteService,
    save: @escaping @Sendable (Item) async throws -> Void,
    lifecycle: any AppLifecycle,
    conditions: any NetworkConditions,
    isThermallyConstrained: @escaping @Sendable () -> Bool = {
      ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    },
    coverPassCompletions: AsyncStream<Void>
  ) {
    self.items = items
    self.service = service
    self.save = save
    self.lifecycle = lifecycle
    self.conditions = conditions
    self.isThermallyConstrained = isThermallyConstrained

    observers = [
      Task { [weak self, lifecycle] in
        for await transition in lifecycle.transitions {
          guard let self else { return }
          switch transition {
          case .background: self.stop()
          case .foreground: self.trigger()
          }
        }
      },
      Task { [weak self, conditions] in
        for await snapshot in conditions.changes {
          guard let self else { return }
          if snapshot.isLowPowerMode { self.stop() } else { self.trigger() }
        }
      },
      Task { [weak self] in
        for await _ in coverPassCompletions {
          self?.trigger()
        }
      },
    ]
  }

  var isRunning: Bool { runTask != nil }

  /// Starts a run, or asks the current one to look again when it finishes. Never runs two at once.
  func trigger() {
    guard mayRun else { return }
    if runTask != nil {
      rerunRequested = true
      return
    }
    runTask = Task(priority: .utility) { [weak self] in
      await self?.run()
    }
  }

  private var mayRun: Bool {
    lifecycle.isForeground && conditions.isLowPowerMode == false
  }

  /// Cancels the run but leaves `runTask` set until it returns, so a trigger arriving while the
  /// cancelled extraction finishes cannot start a second, concurrent one. That trigger is kept and
  /// honoured when the run ends.
  private func stop() {
    runTask?.cancel()
    rerunRequested = false
  }

  private func run() async {
    defer {
      runTask = nil
      if rerunRequested {
        rerunRequested = false
        trigger()
      }
    }
    repeat {
      rerunRequested = false
      let eligible = await items()
      let unsaved = Set(await service.unsaved(eligible.map { CoverPaletteIdentity($0.key) }))
      let candidates = eligible.filter { unsaved.contains(CoverPaletteIdentity($0.key)) }
      guard candidates.isEmpty == false else { return }

      var attempted = 0
      for candidate in candidates {
        guard Task.isCancelled == false, mayRun, isThermallyConstrained() == false else { break }
        // Palette work is opportunistic: an extraction or write failure leaves the row missing,
        // and the next trigger offers the item again.
        try? await save(candidate)
        attempted += 1
      }
      Self.logger.info(
        "palette backfill attempted \(attempted) of \(candidates.count) candidates; \(eligible.count) eligible"
      )
    } while rerunRequested && Task.isCancelled == false && mayRun
  }
}
