import Testing

@testable import SyncEngine

/// The Storage Limit slider's choices: a ladder scaled to the device, with whatever is stored
/// always among them.
@Suite struct StorageCeilingStopsTests {
  private static let gigabyte = StorageCeiling.bytesPerGigabyte

  @Test func theLadderEndsAtTheFirstStopThatCoversTheDevice() {
    let stops = StorageCeilingStops.stops(maximumBytes: 26 * Self.gigabyte, including: .unlimited)

    #expect(stops.first == .gigabytes(1))
    #expect(stops.dropLast().last == .gigabytes(32))
    #expect(stops.last == .unlimited)
    #expect(stops.contains(.gigabytes(40)) == false)
  }

  @Test func aDeviceThatSitsExactlyOnAStopEndsThere() {
    let stops = StorageCeilingStops.stops(maximumBytes: 64 * Self.gigabyte, including: .unlimited)

    #expect(stops.dropLast().last == .gigabytes(64))
  }

  @Test func unknownCapacityStopsAtTheFallback() {
    let stops = StorageCeilingStops.stops(maximumBytes: nil, including: .unlimited)

    #expect(stops.dropLast().last == .gigabytes(256))
  }

  @Test func aDeviceLargerThanTheLadderGetsAllOfIt() {
    let stops = StorageCeilingStops.stops(maximumBytes: 4_000 * Self.gigabyte, including: .unlimited)

    #expect(stops.dropLast().last == .gigabytes(1000))
    #expect(stops.count == StorageCeilingStops.ladderGigabytes.count + 1)
  }

  @Test func theSizesTheFirstScreenOfferedAreStillStops() {
    let stops = StorageCeilingStops.stops(maximumBytes: nil, including: .unlimited)

    for gigabytes: Int64 in [4, 8, 16, 32] {
      #expect(stops.contains(.gigabytes(gigabytes)))
    }
  }

  @Test func aStoredValueOffTheLadderIsInsertedInOrder() {
    let stored = StorageCeiling(bytes: 11 * Self.gigabyte)

    let stops = StorageCeilingStops.stops(maximumBytes: 26 * Self.gigabyte, including: stored)

    #expect(stops.contains(stored))
    #expect(stops.prefix { $0 != stored }.last == .gigabytes(10))
    #expect(stops.drop { $0 != stored }.dropFirst().first == .gigabytes(12))
    #expect(stops.last == .unlimited)
  }

  @Test func aStoredValueBeyondTheDeviceIsStillAStop() {
    // Chosen on a larger device and synced here.
    let stored = StorageCeiling.gigabytes(256)

    let stops = StorageCeilingStops.stops(maximumBytes: 26 * Self.gigabyte, including: stored)

    #expect(stops.suffix(3) == [.gigabytes(32), stored, .unlimited])
  }

  @Test func stopsAreStrictlyIncreasingBeforeUnlimited() {
    let stops = StorageCeilingStops.stops(
      maximumBytes: nil, including: StorageCeiling(bytes: 4_294_967_296))
    let bytes = stops.dropLast().compactMap(\.bytes)

    #expect(bytes.count == stops.count - 1)
    #expect(zip(bytes, bytes.dropFirst()).allSatisfy { $0 < $1 })
  }

  @Test func indexFindsAnExactStopOrTheNearestOne() {
    let stops = StorageCeilingStops.stops(maximumBytes: 26 * Self.gigabyte, including: .unlimited)

    #expect(StorageCeilingStops.index(of: .gigabytes(8), in: stops) == 7)
    #expect(StorageCeilingStops.index(of: .unlimited, in: stops) == stops.count - 1)
    // 11 GB is not a stop here; 10 and 12 are equally near and the lower one wins.
    #expect(stops[StorageCeilingStops.index(of: .gigabytes(11), in: stops)] == .gigabytes(10))
    #expect(stops[StorageCeilingStops.index(of: .gigabytes(500), in: stops)] == .gigabytes(32))
  }

  @Test func adjustingMovesOneStopAndHoldsAtEitherEnd() {
    let stops = StorageCeilingStops.stops(maximumBytes: 26 * Self.gigabyte, including: .unlimited)

    #expect(StorageCeilingStops.stop(from: .gigabytes(8), offset: 1, in: stops) == .gigabytes(10))
    #expect(StorageCeilingStops.stop(from: .gigabytes(8), offset: -1, in: stops) == .gigabytes(7))
    #expect(StorageCeilingStops.stop(from: .gigabytes(1), offset: -1, in: stops) == .gigabytes(1))
    #expect(StorageCeilingStops.stop(from: .gigabytes(32), offset: 1, in: stops) == .unlimited)
    #expect(StorageCeilingStops.stop(from: .unlimited, offset: 1, in: stops) == .unlimited)
    #expect(StorageCeilingStops.stop(from: .unlimited, offset: -1, in: stops) == .gigabytes(32))
  }
}
