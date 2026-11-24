import Foundation
import Network
import WatchPlayback
import WatchProtocol

@main
struct DownloadGroupRegression {
  static func main() throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account-a", serverIdentityHash: "server-a")
    let otherStamp = try WatchAccountStamp(accountIdentityHash: "account-b", serverIdentityHash: "server-a")
    let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    func row(
      _ index: Int = 0, count: Int = 2, state: WatchDownloadState = .completed,
      bytes: Int64? = 100, received: Int64 = 100, selection: WatchSelection? = nil,
      account: WatchAccountStamp? = nil, group: String = "book"
    ) -> WatchDownloadManifest {
      WatchDownloadManifest(
        id: UUID(), accountStamp: account ?? stamp, selection: selection ?? book,
        downloadGroupID: group, expectedTrackCount: count, fileID: "track-\(index)", fileIndex: index,
        startOffset: Double(index) * 60, duration: 60, expectedBytes: bytes,
        expectedMIMEType: "audio/mpeg", destinationRelativePath: "track-\(index).mp3",
        state: state, receivedBytes: received, createdAt: .distantPast, updatedAt: .distantPast)
    }
    func group(_ rows: [WatchDownloadManifest]) -> WatchDownloadGroup {
      let result = WatchDownloadGroup.groups(from: rows)
      precondition(result.count == 1)
      return result[0]
    }
    let ready = group([row(0), row(1)])
    precondition(ready.isReady && ready.completedTrackCount == 2 && ready.progress == 1)
    // Fewer files than the plan is still being enqueued, not a failure.
    let partial = group([row(0)])
    precondition(!partial.isReady && partial.state == .enqueuing && partial.progress == nil)
    let duplicate = group([row(0), row(0)])
    precondition(!duplicate.isReady && duplicate.progress == nil)
    let incompatible = group([row(0), row(1, count: 3)])
    precondition(incompatible.state == .failed && incompatible.manifestIDs.count == 2)
    let wrongGroup = group([row(0), row(1, group: "replacement")])
    precondition(wrongGroup.state == .failed)
    let downloading = group([row(0), row(1, state: .downloading, received: 50)])
    precondition(downloading.state == .downloading && downloading.progress == 0.75)
    let unknown = group([row(0), row(1, state: .queued, bytes: nil, received: 0)])
    precondition(unknown.state == .waiting && unknown.progress == nil)
    let failed = group([row(0), row(1, state: .failed, received: 10)])
    precondition(failed.state == .failed)
    let overflow = group([row(0, bytes: .max, received: .max), row(1, bytes: .max, received: .max)])
    precondition(overflow.progress == nil && overflow.receivedBytes == .max)
    let accounts = WatchDownloadGroup.groups(from: [row(0, count: 1), row(0, count: 1, account: otherStamp)])
    precondition(accounts.count == 2 && Set(accounts.map(\.id)).count == 2)
    let collision = WatchDownloadGroup.groups(from: [
      row(0, count: 1, selection: .audiobookshelf(itemID: "a:b", episodeID: "c")),
      row(0, count: 1, selection: .audiobookshelf(itemID: "a", episodeID: "b:c")),
    ])
    precondition(collision.count == 2 && Set(collision.map(\.id)).count == 2)
    precondition(WatchDownloadGroup.groups(from: []).isEmpty)
    var paused = row(0, count: 1, state: .paused)
    let pausedGroup = group([paused])
    let pausedPresentation = WatchDownloadRowPresentation(
      group: pausedGroup, manifests: [paused], labels: [paused.id.uuidString: "Saved title"])
    precondition(pausedPresentation.status == "Paused" && pausedPresentation.canRetry)
    precondition(pausedPresentation.title == "Saved title")
    paused.failureReason = .waitingForWiFi
    let wifiPresentation = WatchDownloadRowPresentation(group: pausedGroup, manifests: [paused], labels: [:])
    precondition(wifiPresentation.status == "Waiting for Wi-Fi" && wifiPresentation.title == "Downloaded title")
    // A queued row held by the Wi-Fi policy must still offer Retry; without it the hold had no
    // manual escape once the path stopped changing.
    var held = row(0, count: 1, state: .queued, received: 0)
    held.failureReason = .waitingForWiFi
    let heldGroup = group([held])
    let heldPresentation = WatchDownloadRowPresentation(group: heldGroup, manifests: [held], labels: [:])
    precondition(heldPresentation.status == "Waiting for Wi-Fi" && heldPresentation.canRetry)
    // A label on any member names the row, not only the first manifest by sorted identifier.
    let firstTrack = row(0)
    let secondTrack = row(1)
    let labelled = group([firstTrack, secondTrack])
    let labelledPresentation = WatchDownloadRowPresentation(
      group: labelled, manifests: [firstTrack, secondTrack],
      labels: [labelled.manifestIDs[1].uuidString: "The Hobbit"])
    precondition(labelledPresentation.title == "The Hobbit")
    // Network admission is `WatchDownloadNetworkPolicy.admitsAutomaticTransfer`, covered by
    // Core's `WatchDownloadAdmissionTests`.
    let partialPresentation = WatchDownloadRowPresentation(group: partial, manifests: [], labels: [:])
    precondition(partialPresentation.status == "Preparing" && partialPresentation.canRetry)
    // A file refused for want of space declines the whole group, and Retry is offered.
    var refused = row(1, state: .failed, received: 0)
    refused.failureReason = .storage
    let declined = group([row(0), refused])
    precondition(declined.state == .declined)
    let declinedPresentation = WatchDownloadRowPresentation(group: declined, manifests: [], labels: [:])
    precondition(declinedPresentation.status == "Not enough space" && declinedPresentation.canRetry)
    let downloadingPresentation = WatchDownloadRowPresentation(group: downloading, manifests: [], labels: [:])
    precondition(downloadingPresentation.status == "Downloading" && !downloadingPresentation.canRetry)
    let readyPresentation = WatchDownloadRowPresentation(group: ready, manifests: [], labels: [:])
    precondition(readyPresentation.status == "Ready on Watch" && !readyPresentation.canRetry)
    print("Watch download grouping: 13 grouping scenarios and row presentation passed")
  }
}
