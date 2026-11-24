import Foundation
import Persistence
import WatchProtocol

/// The Watch's latest report of progress it has not uploaded, for the bound account only. Held in
/// memory: the Watch resends on its next change, and answers a query before every start that
/// needs it, so a relaunch loses nothing the phone could act on.
@MainActor
final class WatchPendingProgressInbox {
  private let currentStamp: @MainActor () -> WatchAccountStamp?
  private var latest: WatchPendingProgressReport?

  init(currentStamp: @escaping @MainActor () -> WatchAccountStamp?) {
    self.currentStamp = currentStamp
  }

  /// The held report while it still belongs to the bound account.
  var report: WatchPendingProgressReport? {
    guard let latest, let stamp = currentStamp(), latest.accountStamp == stamp else { return nil }
    return latest
  }

  /// A queued report is kept only when it is newer than the one held; transfers can arrive out of
  /// order. A reply to a query is the Watch's current word and always replaces it, which also
  /// recovers from a sequence reset when the Watch app is reinstalled.
  @discardableResult
  func receive(_ incoming: WatchPendingProgressReport, isReply: Bool = false) -> Bool {
    guard let stamp = currentStamp(), incoming.accountStamp == stamp else { return false }
    if !isReply, let held = report, incoming.sequence <= held.sequence { return false }
    latest = incoming
    return true
  }
}

/// Decides, before a phone start, whether the Watch holds a newer position for the title.
@MainActor
struct WatchPendingProgressStartGate {
  /// How long a start waits for the Watch to upload and answer. It adds directly to start latency,
  /// so it stays short; without an answer the held report decides.
  static let watchPendingProgressWait: Duration = .seconds(2)

  let inbox: WatchPendingProgressInbox
  let isActive: @MainActor (_ itemID: String, _ episodeID: String?) -> Bool
  let query: @MainActor (WatchPendingProgressQuery) async -> WatchPendingProgressReport?
  let stored: @MainActor (_ itemID: String, _ episodeID: String?) -> StoredAudioProgress?
  var now: @MainActor () -> Date = { Date() }

  /// The Watch's position when the offline rule picks it over the phone's stored progress, else
  /// `nil` to leave the phone's start unchanged. Titles the Watch never reported, and the title
  /// already loaded here, are not queried.
  func position(itemID: String, episodeID: String?) async -> Double? {
    guard let held = inbox.report, held.entry(itemID: itemID, episodeID: episodeID) != nil,
      !isActive(itemID, episodeID),
      let selection = try? WatchABSSelection(itemID: itemID, episodeID: episodeID),
      let request = try? WatchPendingProgressQuery(accountStamp: held.accountStamp, selection: selection)
    else { return nil }
    let reply = await query(request)
    if let reply, inbox.receive(reply, isReply: true) {
      // The Watch answered after trying to upload: no entry means the server now has its listen.
      guard reply.entry(itemID: itemID, episodeID: episodeID) != nil else { return nil }
    }
    guard let report = inbox.report else { return nil }
    let phone = stored(itemID, episodeID)
    return report.startPosition(
      itemID: itemID, episodeID: episodeID, sharedPosition: phone?.position,
      sharedUpdatedAt: phone?.changedAt, now: now())
  }
}
