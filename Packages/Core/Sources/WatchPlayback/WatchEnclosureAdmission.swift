import Foundation
import WatchProtocol

/// The space the Watch reserves for an enclosure it is about to download (ADR 0020 Decision 2).
/// It mirrors `RSSFileStore.admissionBytes` (Persistence/RSSFileStore.swift:72) without that
/// store's 500 MB free-space reserve: the Watch bounds space by its own 2 GB budget and never
/// reads free disk space, so there is no free-space figure to keep back from.
public enum WatchEnclosureAdmission {
  public static let headroomFraction = 0.10
  public static let headroomMinimumBytes: Int64 = 1_048_576

  /// Bytes to reserve before the download starts. The feed's declared length is only an estimate
  /// here, never a bound: a host that inserts ads serves a different length, and the download is
  /// validated against the bytes it actually received. A length the feed did not give reserves the
  /// whole 1 GiB cap, because the Watch has nothing smaller to promise.
  public static func reservationBytes(declaredBytes: Int64?) -> Int64 {
    guard let declaredBytes, declaredBytes > 0 else {
      return WatchEpisodeSendLimits.maxEpisodeBytes
    }
    let headroom = max(
      Int64(Double(declaredBytes) * headroomFraction),
      headroomMinimumBytes)
    let (reservation, overflow) = declaredBytes.addingReportingOverflow(headroom)
    let total = overflow ? Int64.max : reservation
    return min(total, WatchEpisodeSendLimits.maxEpisodeBytes)
  }
}
