import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The reservation the Watch takes before it downloads an enclosure (ADR 0020 Decision 2).
struct WatchEnclosureAdmissionTests {
  private let cap = WatchEpisodeSendLimits.maxEpisodeBytes
  private let mib: Int64 = 1_048_576

  @Test func anUnknownLengthReservesTheWholeCap() {
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: nil) == cap)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 0) == cap)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: -1) == cap)
  }

  @Test func theMinimumHeadroomCoversASmallEpisode() {
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 1) == 1 + mib)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 1_000) == 1_000 + mib)
  }

  @Test func tenPercentHeadroomCoversALargeEpisode() {
    // 10% of 10 MB is under the 1 MiB floor, so the floor applies.
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 10_000_000) == 10_000_000 + mib)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 40_000_000) == 44_000_000)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: 500_000_000) == 550_000_000)
  }

  @Test func theReservationNeverExceedsTheEpisodeCap() {
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: cap) == cap)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: cap - 1) == cap)
    #expect(WatchEnclosureAdmission.reservationBytes(declaredBytes: Int64.max) == cap)
  }

  /// The one difference from `RSSFileStore.admissionBytes`: no free-space reserve, because the
  /// Watch has no free-space figure to apply.
  @Test func anUnknownLengthDoesNotAddThePhoneFreeSpaceReserve() {
    #expect(
      WatchEnclosureAdmission.reservationBytes(declaredBytes: nil)
        == WatchEpisodeSendLimits.maxEpisodeBytes)
  }
}
