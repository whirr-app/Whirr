import SwiftUI
import Testing
import UIKit

@testable import Whirr

@MainActor
@Suite("Player display corner radius", .serialized)
struct PlayerDisplayCornerRadiusTests {
  private final class MeasureLog {
    var calls = 0
    var answer: CGFloat?
  }

  private func cache(_ log: MeasureLog) -> PlayerDisplayCornerRadius {
    PlayerDisplayCornerRadius(fallback: 48) { _ in
      log.calls += 1
      return log.answer
    }
  }

  @Test("without a window the constant is used and nothing is measured")
  func noWindowFallsBack() {
    let log = MeasureLog()
    log.answer = 55
    #expect(cache(log).radius(for: nil) == 48)
    #expect(log.calls == 0)
  }

  @Test("a window is measured once per size and the answer reused")
  func measuresOncePerWindowSize() async {
    await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: 402, height: 874)) { scope in
      let log = MeasureLog()
      log.answer = 55
      let radius = cache(log)
      #expect(radius.radius(for: scope.window) == 55)
      #expect(radius.radius(for: scope.window) == 55)
      #expect(log.calls == 1)

      // A resized window (an iPad window being dragged larger) is a new key.
      scope.window.frame = CGRect(x: 0, y: 0, width: 600, height: 874)
      log.answer = 0
      #expect(radius.radius(for: scope.window) == 0)
      #expect(log.calls == 2)
    }
  }

  @Test("an unusable measurement falls back and is not cached", arguments: [nil, -1, .nan, .infinity])
  func unusableMeasurementFallsBack(answer: CGFloat?) async {
    await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: 402, height: 874)) { scope in
      let log = MeasureLog()
      log.answer = answer
      let radius = cache(log)
      #expect(radius.radius(for: scope.window) == 48)
      #expect(radius.radius(for: scope.window) == 48)
      #expect(log.calls == 2)
    }
  }

  @Test("the real measurement reads the display's corners on a full-screen phone window")
  func realMeasurement() async throws {
    try await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: 1, height: 1)) { scope in
      let screen = try #require(scope.window.windowScene?.screen.bounds)
      scope.window.frame = screen
      let measured = PlayerDisplayCornerRadius.measureConcentric(in: scope.window)
      let value = try #require(measured)
      print("Measured display corner radius: \(value) pt for \(screen.size)")
      #expect(value.isFinite)
      #expect(value >= 0)
      if UIDevice.current.userInterfaceIdiom == .phone {
        #expect(value > 0)
      }
      // The probe leaves nothing behind in the window.
      #expect(scope.window.subviews.allSatisfy { !($0 is PlayerDisplayCornerRadius.Probe) })
    }
  }
}
