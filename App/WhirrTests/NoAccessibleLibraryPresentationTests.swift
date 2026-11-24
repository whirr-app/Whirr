import AppModel
import Testing

@testable import Whirr

@MainActor
@Suite("No-library recovery presentation")
struct NoAccessibleLibraryPresentationTests {

  @Test("the no-library recovery state exposes library choice only when an accessible row remains")
  func activeStateOffersTheApplicableRecoveryActions() {
    #expect(
      NoAccessibleLibraryViewPresentation.actions(isNoAccessibleLibrary: true, canChooseLibraries: true)
        == [.retry, .chooseLibraries, .signOut])
    #expect(
      NoAccessibleLibraryViewPresentation.actions(isNoAccessibleLibrary: true, canChooseLibraries: false)
        == [.retry, .signOut])
    #expect(
      NoAccessibleLibraryViewPresentation.actions(isNoAccessibleLibrary: false, canChooseLibraries: true)
        .isEmpty)
  }
}
