import Testing

@testable import CoreSupport

@Suite("Library refresh performance trace")
struct LibraryRefreshPerfTraceTests {

  /// The metadata tail is read by counting `commit=metadata` lines. A pass that returns four
  /// batches must produce four lines, and each must say how many rows its one transaction carried.
  @Test("a committed metadata batch names its index and its row count")
  func metadataCommitLineCarriesItsBatchSize() {
    #expect(
      LibraryRefreshPerfTrace.line(.metadataCommit(index: 1, items: 50))
        == "WHIRRPERF library commit=metadata batch=1 items=50")
    #expect(
      LibraryRefreshPerfTrace.line(.metadataCommit(index: 4, items: 12))
        == "WHIRRPERF library commit=metadata batch=4 items=12")
  }

  /// The published/deferred split is the whole projection half of the bracket: the two outcomes
  /// have to be distinguishable in one grep, and both have to report the rows they carried so a
  /// deferred run can be matched against the publication that eventually releases it.
  @Test("a projection decision names its outcome and its row count")
  func projectionLineDistinguishesPublicationFromDeferral() {
    #expect(
      LibraryRefreshPerfTrace.line(.projection(.published, items: 812))
        == "WHIRRPERF library projection=published items=812")
    #expect(
      LibraryRefreshPerfTrace.line(.projection(.deferred, items: 812))
        == "WHIRRPERF library projection=deferred items=812")
  }
}
