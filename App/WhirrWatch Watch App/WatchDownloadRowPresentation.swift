import Foundation
import WatchPlayback

struct WatchDownloadRowPresentation {
  let title: String
  let status: String
  let canRetry: Bool

  init(group: WatchDownloadGroup, manifests: [WatchDownloadManifest], labels: [String: String]) {
    let members = manifests.filter { group.manifestIDs.contains($0.id) }
    // Any member's label names the same title, so a missing label on the first track must not
    // erase a name the other tracks still carry.
    title = group.manifestIDs.lazy.compactMap { labels[$0.uuidString] }.first ?? "Downloaded title"
    // A Wi-Fi hold leaves the row `queued`. Without Retry here a hold that outlived its path change
    // was a dead end.
    let heldForWiFi =
      group.state == .waitingForNetwork
      || (!group.isReady && members.contains { $0.failureReason == .waitingForWiFi })
    let paused = members.contains { $0.state == .paused }
    // `enqueuing`: fewer files than the plan, because they are still being enqueued or a launch
    // ended first. Retry enqueues the rest.
    canRetry =
      heldForWiFi || paused || group.state == .failed || group.state == .declined || group.state == .enqueuing
    if heldForWiFi {
      status = "Waiting for Wi-Fi"
    } else if group.state == .waiting && paused {
      status = "Paused"
    } else {
      switch group.state {
      case .enqueuing: status = "Preparing"
      case .waiting, .waitingForNetwork: status = "Waiting"
      case .downloading: status = "Downloading"
      case .failed: status = "Failed"
      case .declined: status = "Not enough space"
      case .ready: status = "Ready on Watch"
      }
    }
  }
}
