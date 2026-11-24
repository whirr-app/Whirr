import Foundation
import SyncEngine

/// User-facing copy for `StorageModel`, owned and tested entirely in AppModel. Purge copy is
/// explicit about what is destroyed, never a bare "Are you sure?".
public enum StorageCopy {
  public static let purgeItemTitle = "Remove downloads?"
  public static func purgeItemMessage(title: String) -> String {
    "This removes all downloads for \"\(title)\" from this device."
  }

  public static let purgeAllTitle = "Remove all downloads?"
  /// The purge-all action, distinct from `purgeAllTitle`'s confirmation question: the row that
  /// begins the flow reads as a command, not a question the user cannot answer inline.
  public static let purgeAllAction = "Remove All Downloads"
  public static let purgeAllMessage =
    "This removes all downloads from your server and from podcasts you follow on this device."

  /// Every download removal's confirm button: the item stays on the server, so not "Delete".
  public static let confirmRemove = MediaActionCopy.removeSwipeTitle
  public static let cancel = "Cancel"

  /// Shown on a row whose purge is in flight (marked `deleting` before the file/row removal
  /// finishes).
  public static let deletingProgress = "Removing…"

  /// A purge that couldn't complete. Surfaced because a failed delete and an unsent delete would
  /// otherwise look identical.
  public static let purgeFailed = "Couldn't remove these downloads. Try again."

  /// The low-disk queue-pause banner.
  public static let lowDiskBanner =
    "Downloads are paused because this device is low on storage. Free up space to continue."

  /// Disclosure for the last automatic ceiling pass. The byte figure comes from the coordinator's
  /// completed deletion results, not its candidate estimate.
  public static func storageCeilingEvictionSummary(
    _ summary: StorageCeilingEvictionSummary
  ) -> String {
    let removed = formattedBytes(summary.removedBytes)
    if summary.reachedTarget {
      return "Automatically removed \(removed) to stay under your storage limit."
    }
    return "Automatically removed \(removed); some protected downloads remain above your storage limit."
  }

  // MARK: - Reclaiming a removed episode's stranded download

  /// A row's byte line: the item's own total, plus the share of it stranded behind a podcast
  /// episode the server no longer lists (`Persistence`'s `tombstonedEpisodeBytes`). A zero share
  /// is not rendered.
  public static func itemSizeDetail(totalBytes: Int64, removedEpisodeBytes: Int64) -> String {
    guard removedEpisodeBytes > 0 else { return formattedBytes(totalBytes) }
    return "\(formattedBytes(totalBytes)), including \(formattedBytes(removedEpisodeBytes)) from removed episodes"
  }

  /// The reclaim action, distinct from `reclaimEpisodesTitle`'s confirmation question. A command
  /// carrying the real figure, so the offer is never a mysterious button.
  public static func reclaimEpisodesAction(bytes: Int64) -> String {
    "Reclaim \(formattedBytes(bytes)) from Removed Episodes"
  }

  public static let reclaimEpisodesTitle = "Reclaim removed episode downloads?"

  /// States the scope: only audio for episodes the server has stopped listing, which have no
  /// per-episode remove action on a show screen.
  public static func reclaimEpisodesMessage(bytes: Int64) -> String {
    "This deletes \(formattedBytes(bytes)) of downloaded audio for podcast episodes this server no longer lists. Episodes still shown on a podcast are not affected, and nothing is removed from the server."
  }

  /// A reclaim that couldn't complete. A silent no-op would look like a dead button.
  public static let reclaimEpisodesFailed = "Couldn't reclaim these downloads. Try again."

  /// The one byte formatter this screen's copy uses, so a figure quoted in the action, the
  /// confirmation and the row it came from reads identically.
  static func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
