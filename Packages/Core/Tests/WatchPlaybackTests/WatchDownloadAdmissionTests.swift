import Testing
import WatchPlayback

/// The automatic Wi-Fi admission decision the Watch app makes from `NWPathMonitor`. On a real
/// Watch, TN3135 restricts path monitoring outside an active audio session, so the monitor reports
/// an unsatisfied path while URLSession reaches the network through the paired iPhone.
@Suite("Watch download admission")
struct WatchDownloadAdmissionTests {

  @Test("an unsatisfied path admits, because watchOS reports one while the network works")
  func unsatisfiedPathAdmits() {
    #expect(WatchDownloadNetworkPolicy.admitsAutomaticTransfer(pathSatisfied: false, pathUsesCellular: false))
  }

  @Test("a satisfied non-cellular path admits")
  func satisfiedRelayAdmits() {
    #expect(WatchDownloadNetworkPolicy.admitsAutomaticTransfer(pathSatisfied: true, pathUsesCellular: false))
  }

  @Test("a satisfied path on the Watch's own cellular radio holds")
  func satisfiedCellularHolds() {
    #expect(!WatchDownloadNetworkPolicy.admitsAutomaticTransfer(pathSatisfied: true, pathUsesCellular: true))
  }
}
