import SwiftUI
import Testing

@testable import Whirr

@Suite("Sheet view presentation")
struct SheetViewPresentationTests {
  @Test("compact and nil size classes select compact sheet modes")
  func compactAndNilSizeClassesSelectCompactModes() {
    let sizeClasses: [UserInterfaceSizeClass?] = [.compact, nil]

    for sizeClass in sizeClasses {
      #expect(
        SheetViewPresentation.mode(for: sizeClass, role: .episodeCard) == .compactDetents)
      #expect(SheetViewPresentation.mode(for: sizeClass, role: .large) == .compactLarge)
      #expect(SheetViewPresentation.mode(for: sizeClass, role: .form) == .compactDetents)
      #expect(SheetViewPresentation.mode(for: sizeClass, role: .fitted) == .compactDetents)
      #expect(SheetViewPresentation.mode(for: sizeClass, role: .page) == .compactLarge)
    }
  }

  @Test("regular size class selects page, form, and fitted modes by role")
  func regularSizeClassSelectsRegularModesByRole() {
    #expect(
      SheetViewPresentation.mode(for: .regular, role: .episodeCard) == .regularPage)
    #expect(SheetViewPresentation.mode(for: .regular, role: .large) == .regularForm)
    #expect(SheetViewPresentation.mode(for: .regular, role: .form) == .regularForm)
    #expect(SheetViewPresentation.mode(for: .regular, role: .fitted) == .regularFitted)
    #expect(SheetViewPresentation.mode(for: .regular, role: .page) == .regularFullPage)
  }

  @Test("the explicit exemption remains exempt at every width")
  func exemptionRemainsExempt() {
    let sizeClasses: [UserInterfaceSizeClass?] = [.compact, .regular, nil]
    for sizeClass in sizeClasses {
      #expect(SheetViewPresentation.mode(for: sizeClass, role: .exemption) == .exempt)
    }
  }
}
