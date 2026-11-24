import Testing
import WatchPlayback

/// Whether a group's file indices account for every track the plan expected. Audiobookshelf
/// numbers audio files from 1, so a check written against `0..<count` reads every real book as
/// an incomplete plan and the Watch row as failed.
@Suite("Watch download plan coverage")
struct WatchDownloadPlanCoverageTests {

  @Test("a single-file book indexed from 1, as the server sends it, is a complete plan")
  func singleServerIndexedFileCovers() {
    #expect(WatchDownloadManifest.indicesCoverPlan([1], expectedCount: 1))
  }

  @Test("a multi-file book indexed from 1 is a complete plan in any order")
  func multipleServerIndexedFilesCover() {
    #expect(WatchDownloadManifest.indicesCoverPlan([3, 1, 2], expectedCount: 3))
  }

  @Test("rows indexed from 0 still count, so existing manifests keep their state")
  func zeroIndexedFilesCover() {
    #expect(WatchDownloadManifest.indicesCoverPlan([0, 1], expectedCount: 2))
  }

  @Test("a repeated index is not a complete plan")
  func repeatedIndexDoesNotCover() {
    #expect(!WatchDownloadManifest.indicesCoverPlan([1, 1], expectedCount: 2))
  }

  @Test("fewer rows than the plan expected is not a complete plan")
  func missingRowDoesNotCover() {
    #expect(!WatchDownloadManifest.indicesCoverPlan([1, 2], expectedCount: 3))
  }

  @Test("a gap in the server's numbering does not fail a plan with every track present")
  func gappedIndicesCover() {
    #expect(WatchDownloadManifest.indicesCoverPlan([1, 3], expectedCount: 2))
  }

  @Test("a plan larger than the store accepts is not complete")
  func oversizedPlanDoesNotCover() {
    #expect(!WatchDownloadManifest.indicesCoverPlan(Array(1...129), expectedCount: 129))
  }
}
