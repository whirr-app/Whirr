import Testing

@testable import Persistence

@Suite struct EpisodeDownloadProgressProjectionTests {
  @Test func floorsFractionsToTheQuantumAndClampsOverruns() {
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 0, expectedBytes: 1_000) == 0)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 39, expectedBytes: 1_000) == 0.02)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 41, expectedBytes: 1_000) == 0.04)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 1_000, expectedBytes: 1_000) == 1)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 5_000, expectedBytes: 1_000) == 1)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: -5, expectedBytes: 1_000) == 0)
  }

  @Test func reportsNoFractionForAnUnknownTotal() {
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 500, expectedBytes: 0) == nil)
    #expect(EpisodeDownloadProgressProjection.quantizedFraction(receivedBytes: 500, expectedBytes: -1) == nil)
  }

  @Test func floorsBytesToTheQuantumOfTheTotalOrToMebibytesWithoutOne() {
    #expect(EpisodeDownloadProgressProjection.quantizedBytes(receivedBytes: 47, expectedBytes: 1_000) == 40)
    #expect(EpisodeDownloadProgressProjection.quantizedBytes(receivedBytes: 1_000, expectedBytes: 1_000) == 1_000)
    #expect(EpisodeDownloadProgressProjection.quantizedBytes(receivedBytes: 2_500_000, expectedBytes: nil) == 2_097_152)
    #expect(EpisodeDownloadProgressProjection.quantizedBytes(receivedBytes: 2_500_000, expectedBytes: 0) == 2_097_152)
    #expect(EpisodeDownloadProgressProjection.quantizedBytes(receivedBytes: 500, expectedBytes: nil) == 0)
  }
}
