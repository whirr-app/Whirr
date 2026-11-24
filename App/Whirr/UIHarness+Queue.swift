#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Foundation
  import Persistence
  import SwiftUI

  extension UIHarness {
    /// `WHIRR_UI_HARNESS_PRESENTED=1` raises the harness player through the shipping interactive
    /// presentation instead of embedding it, so the pull-down dismissal can be exercised.
    static var presentsPlayerInteractively: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_PRESENTED"] == "1"
    }

    /// `WHIRR_UI_HARNESS_QUEUE=<n>` seeds the harness player's Up Next with `n` fixture rows, so the
    /// queue's populated state, scrolling and editing can be exercised without a server.
    static var queueFixtureCount: Int {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_QUEUE"].flatMap(Int.init) ?? 0
    }

    @MainActor
    static func makeListeningQueueModel() -> ListeningQueueModel {
      let count = queueFixtureCount
      guard count > 0 else { return ListeningQueueModel() }
      let store = HarnessListeningQueueStore(count: count)
      return ListeningQueueModel(reading: store, storing: store)
    }
  }

  private struct HarnessInteractivePlayer<Player: View>: ViewModifier {
    let colorScheme: ColorScheme
    @ViewBuilder let player: () -> Player
    @State private var isPresented = false

    func body(content: Content) -> some View {
      if UIHarness.presentsPlayerInteractively {
        content
          .overlay(alignment: .bottom) {
            Button("Present player") { isPresented = true }
              .buttonStyle(.borderedProminent)
              .padding()
          }
          .interactivePlayerPresentation(
            isPresented: $isPresented, chromeColorScheme: colorScheme, onDismissCompleted: {},
            content: player
          )
          .task {
            // The presenter needs a window before it can present.
            try? await Task.sleep(for: .milliseconds(600))
            isPresented = true
          }
      } else {
        content
      }
    }
  }

  extension View {
    func harnessInteractivePlayer<Player: View>(
      colorScheme: ColorScheme, @ViewBuilder player: @escaping () -> Player
    ) -> some View {
      modifier(HarnessInteractivePlayer(colorScheme: colorScheme, player: player))
    }
  }

  /// An in-memory Up Next for the harness. Edits apply to the fixture rows and republish them, as
  /// the real store's observation does.
  final class HarnessListeningQueueStore: ListeningQueueReading, ListeningQueueStoring,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var items: [ListeningQueueItem]
    private var cleared: [ListeningQueueItem] = []
    private var continuations: [UUID: AsyncStream<[ListeningQueueItem]>.Continuation] = [:]

    private static let titles: [(String, String)] = [
      ("Greenmantle", "John Buchan"),
      ("The Secret Agent", "Joseph Conrad"),
      ("Episode 212: The Long Way Round", "The Slow Radio Hour"),
      ("Kim", "Rudyard Kipling"),
      ("A Field Guide to Getting Lost", "Rebecca Solnit"),
      ("Episode 48: Tides", "Coastlines"),
      ("The Riddle of the Sands", "Erskine Childers"),
      ("Rogue Male", "Geoffrey Household"),
    ]

    init(count: Int) {
      items = (0..<count).compactMap { index in
        guard let identity = ListeningIdentity.audiobook(itemID: "harness-queue-\(index)") else {
          return nil
        }
        let title = Self.titles[index % Self.titles.count]
        return ListeningQueueItem(
          id: Int64(index), position: index, identity: identity,
          primaryTitle: title.0, secondaryTitle: title.1, category: .audiobook, isTombstone: false)
      }
    }

    func observeQueue() -> AsyncStream<[ListeningQueueItem]> {
      AsyncStream { continuation in
        let id = UUID()
        lock.withLock {
          continuations[id] = continuation
          continuation.yield(items)
        }
        continuation.onTermination = { [weak self] _ in
          self?.lock.withLock { self?.continuations[id] = nil }
        }
      }
    }

    private func mutate(_ change: (inout [ListeningQueueItem]) -> Void) {
      lock.withLock {
        change(&items)
        items = items.enumerated().map { index, item in
          ListeningQueueItem(
            id: item.id, position: index, identity: item.identity,
            primaryTitle: item.primaryTitle, secondaryTitle: item.secondaryTitle,
            category: item.category, isTombstone: item.isTombstone)
        }
        for continuation in continuations.values { continuation.yield(items) }
      }
    }

    @discardableResult
    func append(
      identity: ListeningIdentity, chapter: ListeningQueueChapter?
    ) async throws -> ListeningQueueAppendOutcome { .alreadyQueued }
    func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {}
    @discardableResult
    func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] { [] }

    func remove(identity: ListeningIdentity) async throws {
      mutate { $0.removeAll { $0.identity == identity } }
    }

    func remove(rowID: Int64) async throws {
      mutate { $0.removeAll { $0.id == rowID } }
    }

    func move(rowID: Int64, to position: Int) async throws {
      mutate { items in
        guard let index = items.firstIndex(where: { $0.id == rowID }) else { return }
        let item = items.remove(at: index)
        items.insert(item, at: min(max(position, 0), items.count))
      }
    }

    func clear() async throws -> ListeningQueueRestoreToken {
      mutate { items in
        cleared = items
        items = []
      }
      // The token is opaque outside Persistence; the harness restores from its own copy.
      return try await NoOpListeningQueueStore().clear()
    }

    func restore(token: ListeningQueueRestoreToken) async throws {
      mutate { items in
        items = cleared
        cleared = []
      }
    }

    func peekNextLive() async -> ListeningQueueItem? { lock.withLock { items.first } }

    func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
      mutate { $0.removeAll { $0.identity == identity && ($0.chapter == nil || $0.id == rowID) } }
    }

    /// Consumes the start like `acknowledgeStarted`. Like `insertNext` here, it adds no row for the
    /// displaced title.
    func acknowledgeStarted(
      identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
    ) async throws -> Bool {
      try await acknowledgeStarted(identity: identity, rowID: rowID)
      return false
    }
  }
#endif
