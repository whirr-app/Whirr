/// The storage-ceiling preference as the screens see it: a byte count, or none for unlimited.
///
/// Carries the stored value verbatim: `StorageCeilingCoordinator` enforces whatever
/// `DownloadPreferences.storageCeilingBytes` holds, and the preference syncs as a plain number, so
/// a value this device would never offer can come back. Folding it into "unlimited" would show no
/// limit while one is enforced.
public struct StorageCeiling: Sendable, Hashable {
  public let bytes: Int64?

  public init(bytes: Int64?) {
    self.bytes = bytes
  }

  public static let unlimited = StorageCeiling(bytes: nil)

  public static func gigabytes(_ count: Int64) -> StorageCeiling {
    StorageCeiling(bytes: count * bytesPerGigabyte)
  }

  public var isUnlimited: Bool { bytes == nil }

  /// Decimal, not binary: every byte figure the storage screens show goes through
  /// `ByteCountFormatter`'s `.file` style, which is decimal. A binary constant here would offer a
  /// limit labelled "4.29 GB" and then measure against it in decimal GB.
  public static let bytesPerGigabyte: Int64 = 1_000 * 1_000 * 1_000
}

/// The ordered choices the Storage Limit slider moves between.
public enum StorageCeilingStops {
  /// Whole decimal gigabytes, fine where a phone's downloads usually sit and widening above that.
  /// 4, 8, 16 and 32 are the sizes the first version of the screen offered, so a ceiling chosen
  /// there is still a stop.
  static let ladderGigabytes: [Int64] = [
    1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 128, 150, 200, 256, 400, 512,
    750, 1000,
  ]

  /// Where the ladder ends when the device's capacity could not be read.
  static let unknownCapacityMaximumBytes: Int64 = 256 * StorageCeiling.bytesPerGigabyte

  /// The finite stops this device can reach, then unlimited.
  ///
  /// - `maximumBytes` is the most the device could hold for Whirr (downloaded plus free). The
  ///   ladder runs to the first stop at or above it. `nil` means capacity is unknown.
  /// - `current` is always among the stops, in order, even off the ladder or beyond the device's
  ///   reach: the slider must show what is being enforced.
  public static func stops(maximumBytes: Int64?, including current: StorageCeiling) -> [StorageCeiling] {
    let maximum = maximumBytes ?? unknownCapacityMaximumBytes
    var finite: [Int64] = []
    for gigabytes in ladderGigabytes {
      let bytes = gigabytes * StorageCeiling.bytesPerGigabyte
      finite.append(bytes)
      if bytes >= maximum { break }
    }
    if let currentBytes = current.bytes, finite.contains(currentBytes) == false {
      finite.append(currentBytes)
      finite.sort()
    }
    return finite.map { StorageCeiling(bytes: $0) } + [.unlimited]
  }

  /// The position of `ceiling` among `stops`, or of the nearest stop when it is not one of them.
  /// The stop list is rebuilt as byte totals and capacity load, so a value chosen against one list
  /// may be absent from the next.
  public static func index(of ceiling: StorageCeiling, in stops: [StorageCeiling]) -> Int {
    if let exact = stops.firstIndex(of: ceiling) { return exact }
    guard let bytes = ceiling.bytes else { return max(0, stops.count - 1) }
    var nearest = 0
    var nearestDistance = Int64.max
    for (index, stop) in stops.enumerated() {
      guard let stopBytes = stop.bytes else { continue }
      let distance = abs(stopBytes - bytes)
      if distance < nearestDistance {
        nearest = index
        nearestDistance = distance
      }
    }
    return nearest
  }

  /// The stop `offset` positions from `ceiling`, held at either end. This is how an accessibility
  /// adjust moves the limit, one stop at a time.
  public static func stop(
    from ceiling: StorageCeiling, offset: Int, in stops: [StorageCeiling]
  ) -> StorageCeiling {
    guard stops.isEmpty == false else { return ceiling }
    let target = min(max(index(of: ceiling, in: stops) + offset, 0), stops.count - 1)
    return stops[target]
  }
}
