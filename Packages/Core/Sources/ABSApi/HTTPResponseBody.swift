import Foundation

/// Admission and assembly of a streamed response body under the request's byte cap.
enum ResponseBodyAdmission {
  static func validateContentLength(_ value: String?, maximumBytes: Int?) throws {
    guard let maximumBytes, let value, let contentLength = Int(value), contentLength > maximumBytes
    else { return }
    throw APIError.payloadTooLarge
  }
}

/// Assembles a streamed response body while enforcing its byte cap exactly.
///
/// Bytes are staged in a plain array and flushed into `Data` a block at a time. `AsyncBytes` yields
/// one `UInt8` per iteration, so per-byte `Data.append` would pay a copy-on-write uniqueness check
/// for every byte of a cover (tens of kilobytes, up to `CoverImageAdmission.maximumResponseBytes`
/// unresized), with six covers streaming behind `CoverImageClient`'s gate.
///
/// The cap counts logical bytes, not flushed ones: the byte after the `maximumBytes`-th throws.
struct ResponseBodyAccumulator: Sendable {
  /// Large enough that the per-block costs disappear against the copy itself, small enough that a
  /// capped-out body cannot stage meaningfully more than the cap before the throw.
  private static let stagingBlockBytes = 64 * 1024

  private var storage = Data()
  private var staging: [UInt8] = []
  private var count = 0
  private let maximumBytes: Int?

  /// Correct whether or not `finish()` has run, so a caller reading mid-stream still sees every
  /// byte it appended. `finish()` leaves the staging buffer empty, making this the plain storage.
  var data: Data {
    guard staging.isEmpty else {
      var flushed = storage
      flushed.append(contentsOf: staging)
      return flushed
    }
    return storage
  }

  init(maximumBytes: Int?) {
    self.maximumBytes = maximumBytes
    if let maximumBytes, maximumBytes > 0 {
      storage.reserveCapacity(min(maximumBytes, 1024 * 1024))
    }
    staging.reserveCapacity(min(maximumBytes ?? Self.stagingBlockBytes, Self.stagingBlockBytes))
  }

  mutating func append(_ byte: UInt8) throws {
    if let maximumBytes, count >= maximumBytes {
      throw APIError.payloadTooLarge
    }
    staging.append(byte)
    count += 1
    if staging.count >= Self.stagingBlockBytes {
      flush()
    }
  }

  /// Moves any staged tail into `data`. Idempotent.
  mutating func finish() {
    flush()
  }

  private mutating func flush() {
    guard staging.isEmpty == false else { return }
    storage.append(contentsOf: staging)
    staging.removeAll(keepingCapacity: true)
  }
}
