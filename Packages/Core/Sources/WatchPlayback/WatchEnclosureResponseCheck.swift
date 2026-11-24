import Foundation
import WatchProtocol

/// What a finished enclosure download may hand to the store (ADR 0020 Decisions 2 and 4). The
/// bytes are validated against the final response's own length and the file that arrived, never
/// against the feed's declared length: dynamic ad insertion makes the two differ, and the declared
/// length is only the reservation estimate.
public enum WatchEnclosureResponseCheck {
  /// The accepted byte count, or the reason the copy must be discarded. `contentLength` is the
  /// response's `Content-Length` when the server sent one; `contentRangeTotal` is the whole-file
  /// length from a `Content-Range` header.
  public static func evaluate(
    statusCode: Int, receivedBytes: Int64, contentLength: Int64?, contentRangeTotal: Int64?
  ) -> Result<Int64, WatchEpisodeInventoryEntry.FailureReason> {
    guard statusCode == 200 || statusCode == 206 else { return .failure(.httpStatus) }
    // A resumed transfer finishes with 206 only as the completion of a whole file, so its
    // `Content-Range` total is the whole-file length. Without it there is no way to know the bytes
    // are the whole episode.
    if statusCode == 206 {
      guard let total = contentRangeTotal, total == receivedBytes else {
        return .failure(.invalidResponse)
      }
    }
    guard receivedBytes > 0 else { return .failure(.invalidResponse) }
    guard receivedBytes <= WatchEpisodeSendLimits.maxEpisodeBytes else { return .failure(.tooLarge) }
    if statusCode == 200, let contentLength, contentLength != receivedBytes {
      return .failure(.invalidResponse)
    }
    return .success(receivedBytes)
  }

  /// The whole-file length from a `Content-Range` value such as `bytes 0-99/100`. A `*` total, a
  /// one-sided range and anything malformed yield `nil`; the caller then rejects the download.
  public static func contentRangeTotal(from headerValue: String) -> Int64? {
    let fields = headerValue.split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
    let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let range = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]),
      start >= 0, end >= start
    else { return nil }
    // `*` (an unsatisfied range) and a zero or negative total cannot describe a whole file.
    guard let total = Int64(parts[1]), total > end else { return nil }
    return total
  }
}
