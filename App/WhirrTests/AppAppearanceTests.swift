import SwiftUI
import Testing

@testable import Whirr

@Suite("App appearance")
struct AppAppearanceTests {

  @Test("appearance choices use the native system-light-dark order")
  func choicesAreStable() {
    #expect(AppAppearance.allCases == [.system, .light, .dark])
    #expect(AppAppearance.allCases.map(\.displayName) == ["System", "Light", "Dark"])
  }

  @Test("system follows the device while explicit choices override it")
  func preferredSchemesResolve() {
    #expect(AppAppearance.system.preferredColorScheme == nil)
    #expect(AppAppearance.light.preferredColorScheme == .light)
    #expect(AppAppearance.dark.preferredColorScheme == .dark)
  }

  @Test("unknown persisted values safely fall back to System")
  func unknownStorageFallsBackToSystem() {
    #expect(AppAppearance.resolved("future-value") == .system)
  }

  /// A presented sheet is its own colour-scheme preference boundary. Handing it `nil` does not
  /// clear a preference it already has, so a surface inside a presentation never states "no
  /// preference". It states the scheme the app around it is showing, which for System is the
  /// device's own.
  @Test("inside a presentation, System resolves to the scheme the app is already showing")
  func systemResolvesToTheAmbientSchemeInsideAPresentation() {
    #expect(AppAppearance.system.colorScheme(ambient: .dark) == .dark)
    #expect(AppAppearance.system.colorScheme(ambient: .light) == .light)
    #expect(AppAppearance.light.colorScheme(ambient: .dark) == .light)
    #expect(AppAppearance.dark.colorScheme(ambient: .light) == .dark)
  }
}
