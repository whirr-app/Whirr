import Foundation
import WatchPlayback
import WatchProtocol

extension WatchReceivedEpisode {
  /// The entry still wants the bytes a callback carries. Every terminal state refuses a late
  /// callback, so a task the driver replaced or cancelled cannot settle a row twice.
  var isAwaitingDownload: Bool {
    switch state {
    case .receiving, .downloading, .waitingForNetwork: return true
    case .ready, .failed, .declined, .removed: return false
    }
  }
}
