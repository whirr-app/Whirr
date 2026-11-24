import Foundation
import Observation
import Persistence
import SyncEngine

/// One list's download control: whether it is pinned, how far its downloads have got, and turning
/// the pin on or off, with a confirmation when that downloads a lot or deletes downloads.
@MainActor
@Observable
public final class PinnedListDownloadModel {
  public enum State: Sendable, Equatable {
    case off
    case downloading(done: Int, total: Int)
    case downloaded
    /// Everything left to do is held for Wi-Fi.
    case waitingForWiFi
    /// Failed rows are never retried automatically, so they outrank progress.
    case failed(count: Int)
  }

  public struct Confirmation: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
      case pin
      case unpin
    }

    public let action: Action
    public let title: String
    public let message: String
    public let confirmTitle: String

    public var id: String { title }
  }

  /// More than this many downloads, or more than `confirmationBytes`, asks first.
  static let confirmationCount = 10
  static let confirmationBytes: Int64 = 2_000_000_000

  public let key: LibraryCollectionKey
  public private(set) var isPinned = false
  public private(set) var state: State = .off
  public private(set) var pendingConfirmation: Confirmation?
  public private(set) var isWorking = false
  public private(set) var errorMessage: String?

  private let pins: any PinnedListDownloadControlling
  private var summary: PinnedListDownloadSummary?
  @ObservationIgnored private var keysTask: Task<Void, Never>?
  @ObservationIgnored private var summaryTask: Task<Void, Never>?

  public init(key: LibraryCollectionKey, pins: any PinnedListDownloadControlling) {
    self.key = key
    self.pins = pins
    keysTask = Task { [weak self, pins, key] in
      for await keys in pins.observePinnedKeys() {
        guard let self, Task.isCancelled == false else { return }
        self.isPinned = keys.contains(key)
        self.rederive()
      }
    }
    summaryTask = Task { [weak self, pins, key] in
      for await summary in pins.observeSummary(key) {
        guard let self, Task.isCancelled == false else { return }
        self.summary = summary
        self.rederive()
      }
    }
  }

  deinit {
    keysTask?.cancel()
    summaryTask?.cancel()
  }

  static func state(isPinned: Bool, summary: PinnedListDownloadSummary?) -> State {
    guard isPinned else { return .off }
    guard let summary else { return .downloading(done: 0, total: 0) }
    if summary.failed > 0 { return .failed(count: summary.failed) }
    if summary.completed == summary.total { return .downloaded }
    if summary.active == 0, summary.waitingForWiFi > 0 { return .waitingForWiFi }
    return .downloading(done: summary.completed, total: summary.total)
  }

  /// Pins the list, asking first when it would download a lot.
  public func turnOn() async {
    errorMessage = nil
    do {
      let preview = try await pins.downloadPreview(key)
      let isLarge =
        preview.count > Self.confirmationCount
        || (preview.expectedBytes ?? 0) > Self.confirmationBytes
      if isLarge {
        pendingConfirmation = Confirmation(
          action: .pin,
          title: PinnedListDownloadCopy.pinTitle(count: preview.count, kind: key.kind),
          message: PinnedListDownloadCopy.pinMessage(bytes: preview.expectedBytes),
          confirmTitle: PinnedListDownloadCopy.pinConfirm)
        return
      }
    } catch {
      // A preview that cannot be read is not a reason to refuse the pin.
    }
    await perform(.pin)
  }

  /// Unpins the list, asking first when that deletes downloads.
  public func turnOff() async {
    errorMessage = nil
    let count = (try? await pins.downloadsUnpinningWouldRemove(key)) ?? 0
    guard count > 0 else {
      await perform(.unpin)
      return
    }
    pendingConfirmation = Confirmation(
      action: .unpin,
      title: PinnedListDownloadCopy.unpinTitle(count: count),
      message: PinnedListDownloadCopy.unpinMessage,
      confirmTitle: PinnedListDownloadCopy.unpinConfirm)
  }

  /// Takes the confirmation rather than reading `pendingConfirmation`: an alert clears its
  /// binding before its button's work runs.
  public func confirm(_ confirmation: Confirmation) async {
    pendingConfirmation = nil
    await perform(confirmation.action)
  }

  public func cancelConfirmation() {
    pendingConfirmation = nil
  }

  public func dismissError() {
    errorMessage = nil
  }

  public func retryFailed() async {
    errorMessage = nil
    do {
      try await pins.retryFailed(key)
    } catch {
      errorMessage = PinnedListDownloadCopy.retryFailed
    }
  }

  private func perform(_ action: Confirmation.Action) async {
    guard isWorking == false else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      switch action {
      case .pin: try await pins.pin(key)
      case .unpin: try await pins.unpin(key)
      }
    } catch {
      errorMessage =
        action == .pin ? PinnedListDownloadCopy.pinFailed : PinnedListDownloadCopy.unpinFailed
    }
  }

  private func rederive() {
    state = Self.state(isPinned: isPinned, summary: summary)
  }
}

public enum PinnedListDownloadCopy {
  public static let pinConfirm = "Download"
  public static let unpinConfirm = MediaActionCopy.removeDownloads.title
  public static let unpinMessage = "Items you downloaded yourself stay."
  public static let pinFailed = "Couldn't turn on downloads for this list. Try again."
  public static let unpinFailed = "Couldn't turn off downloads for this list. Try again."
  public static let retryFailed = "Couldn't retry the failed downloads. Try again."
  public static let menuDownload = "Download"
  public static let menuRemove = MediaActionCopy.removeDownloads.title
  public static let menuTryAgain = "Try Again"
  public static let accessibilityDownloaded = "Downloaded"
  public static let accessibilityDownloading = "Downloading"

  static func pinTitle(count: Int, kind: LibraryCollectionListKind) -> String {
    let noun: String
    switch kind {
    case .collection: noun = count == 1 ? "Book" : "Books"
    case .playlist: noun = count == 1 ? "Item" : "Items"
    }
    return "Download \(count) \(noun)?"
  }

  static func pinMessage(bytes: Int64?) -> String {
    let kept = "New items added to this list download too. Pinned downloads are kept even when storage is full."
    guard let bytes, bytes > 0 else { return kept }
    return "About \(StorageCopy.formattedBytes(bytes)). \(kept)"
  }

  static func unpinTitle(count: Int) -> String {
    count == 1 ? "Remove 1 Download?" : "Remove \(count) Downloads?"
  }

  /// The menu's summary line for each state; nil when off.
  public static func status(_ state: PinnedListDownloadModel.State) -> String? {
    switch state {
    case .off: nil
    case .downloading(let done, let total): "Downloaded \(done) of \(total)"
    case .downloaded: "Downloaded"
    case .waitingForWiFi: "Waiting for Wi-Fi"
    case .failed(let count): count == 1 ? "1 failed" : "\(count) failed"
    }
  }
}
