import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Editorial card surface")
@MainActor
struct EditorialCardSurfaceTests {
  @Test("nil wash leaves the surface unchanged")
  func nilWashDoesNotApplyChrome() {
    let modifier = EditorialCardSurfaceModifier(wash: nil)

    #expect(modifier.appliesChrome == false)
  }

  @Test("any wash applies editorial card chrome")
  func washAppliesChrome() {
    #expect(EditorialCardSurfaceModifier(wash: .neutral).appliesChrome)
    #expect(
      EditorialCardSurfaceModifier(
        wash: CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6)
      ).appliesChrome
    )
  }

  @Test("view extension installs the editorial card surface modifier")
  func viewExtensionInstallsModifier() {
    let identity = Color.clear.editorialCardSurface(nil)
    let chrome = Color.clear.editorialCardSurface(.neutral)

    #expect(String(reflecting: type(of: identity)).contains("EditorialCardSurfaceModifier"))
    #expect(String(reflecting: type(of: chrome)).contains("EditorialCardSurfaceModifier"))
  }
}
