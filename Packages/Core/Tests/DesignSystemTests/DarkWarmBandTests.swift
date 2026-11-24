import Testing

@testable import DesignSystem

@Suite("Dark warm band")
struct DarkWarmBandTests {
  private static func share(degrees: Double) -> Double {
    DarkWarmBand.share(hueRadians: degrees * .pi / 180)
  }

  @Test("the warm band peaks at mustard and is gone by red and lemon")
  func bandShape() {
    #expect(Self.share(degrees: 82) == 1)
    #expect(abs(Self.share(degrees: 64.5) - 0.5) < 1e-9)
    #expect(abs(Self.share(degrees: 99.5) - 0.5) < 1e-9)
    for hue in [0.0, 47, 117, 250, 359, -30] {
      #expect(Self.share(degrees: hue) == 0)
    }
  }

  @Test("turning moves a hue towards red by the band's share of the full turn")
  func turnedFollowsShare() {
    for degrees in stride(from: 0.0, to: 360, by: 5) {
      let radians = degrees * .pi / 180
      let turned = DarkWarmBand.turned(hueRadians: radians) * 180 / .pi
      #expect(
        abs((degrees - turned) - DarkWarmBand.turnDegrees * Self.share(degrees: degrees)) < 1e-9)
    }
  }
}
