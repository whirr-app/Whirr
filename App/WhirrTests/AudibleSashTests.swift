import DesignSystem
import Foundation
import Testing
import UIKit

@testable import Whirr

/// Pins that Audible's "Only from Audible" corner sash is not read as a cover's colour.
@Suite struct AudibleSashTests {
  private static let sage = UIColor(red: 0.38, green: 0.47, blue: 0.37, alpha: 1)
  private static let sashYellow = UIColor(red: 0.92, green: 0.86, blue: 0.15, alpha: 1)

  /// A black square cover with a field of muted green and, optionally, the sash: a diagonal band
  /// across the bottom-right corner between `x + y = 1.6` and `1.82` of the side, measured off a
  /// real Audible cover. `lettered` crosses it with thin black strokes, as Audible's "Only from
  /// audible" does, at a pitch finer than one 64-pixel analysis cell of a large cover.
  private static func coverData(
    sash: Bool, greenShare: Double = 0.10, side: CGFloat = 512, lettered: Bool = false
  ) -> Data? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
      .pngData { context in
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        sage.setFill()
        context.fill(CGRect(x: 0, y: side * 0.1, width: side, height: side * greenShare))
        guard sash else { return }
        let band = UIBezierPath()
        band.move(to: CGPoint(x: side * 0.6, y: side))
        band.addLine(to: CGPoint(x: side, y: side * 0.6))
        band.addLine(to: CGPoint(x: side, y: side * 0.82))
        band.addLine(to: CGPoint(x: side * 0.82, y: side))
        band.close()
        sashYellow.setFill()
        band.fill()
        guard lettered else { return }
        UIColor.black.setFill()
        let pitch = side / 50
        for x in stride(from: side * 0.6, to: side, by: pitch) {
          context.fill(CGRect(x: x, y: side * 0.6, width: pitch * 0.25, height: side * 0.4))
        }
      }
  }

  private static func selectedHueDegrees(_ data: Data) async throws -> Double {
    let samples = try #require(await CoverPaletteExtractor.shared.samples(from: data))
    let cluster = try #require(CoverAmbientPalette.palette(from: samples).ambientAppearance.evidence.cluster)
    let degrees = OKLab(red: cluster.red, green: cluster.green, blue: cluster.blue).hueRadians * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }

  @Test("A sashed cover takes its own green, not the sash's yellow")
  func sashIsNotTheCoversColour() async throws {
    let data = try #require(Self.coverData(sash: true))
    let hue = try await Self.selectedHueDegrees(data)
    // Sage sits near 142 degrees, the sash's yellow near 104.
    #expect(abs(hue - 142) < 12)
  }

  @Test(
    "A lettered sash is found whatever size of the cover is analysed",
    arguments: [132, 420, 816, 1_200, 2_400] as [CGFloat])
  func letteredSashAtAnySize(side: CGFloat) async throws {
    let data = try #require(Self.coverData(sash: true, side: side, lettered: true))
    let hue = try await Self.selectedHueDegrees(data)
    #expect(abs(hue - 142) < 12)
  }

  @Test("The same cover without the sash picks the same green")
  func unsashedCoverIsUnchanged() async throws {
    let data = try #require(Self.coverData(sash: false))
    let hue = try await Self.selectedHueDegrees(data)
    #expect(abs(hue - 142) < 12)
  }

  // MARK: - Detection

  private static let side = 64

  /// A top-row-first RGBA float bitmap, black but for `colour` wherever `paints` holds of the
  /// pixel's centre as fractions of the side, from the top left.
  private static func bitmap(
    _ colour: (Float, Float, Float), where paints: (Double, Double) -> Bool
  ) -> [Float] {
    var bitmap = [Float]()
    for row in 0..<side {
      for column in 0..<side {
        let x = (Double(column) + 0.5) / Double(side)
        let y = (Double(row) + 0.5) / Double(side)
        let pixel = paints(x, y) ? colour : (0, 0, 0)
        bitmap += [pixel.0, pixel.1, pixel.2, 1]
      }
    }
    return bitmap
  }

  private static let yellow: (Float, Float, Float) = (0.92, 0.86, 0.15)

  @Test("A yellow band across the bottom-right corner is the sash")
  func detectsTheSash() {
    let sashed = Self.bitmap(Self.yellow) { x, y in (1.6...1.82).contains(x + y) }
    #expect(AudibleSash.isPresent(inRGBAf: sashed, width: Self.side, height: Self.side))
  }

  @Test("Lettering across part of the band still reads as the sash")
  func letteringKeepsTheSash() {
    let sashed = Self.bitmap(Self.yellow) { x, y in
      (1.6...1.82).contains(x + y) && !(0.70...0.74).contains(y)
    }
    #expect(AudibleSash.isPresent(inRGBAf: sashed, width: Self.side, height: Self.side))
  }

  @Test(
    "The band's shape in another colour or corner, or a plain cover, is not the sash",
    arguments: [
      ((0.20, 0.70, 0.30), false),  // A green band in the sash's place.
      ((0.92, 0.86, 0.15), true),  // A yellow band across the top-left corner.
      ((0, 0, 0), false),  // A black cover.
    ] as [((Float, Float, Float), Bool)])
  func rejectsOtherCovers(_ colour: (Float, Float, Float), mirrored: Bool) {
    let cover = Self.bitmap(colour) { x, y in
      (1.6...1.82).contains(mirrored ? 2 - x - y : x + y)
    }
    #expect(!AudibleSash.isPresent(inRGBAf: cover, width: Self.side, height: Self.side))
  }

  @Test("Masking blanks the corner from the band's margin and leaves the rest of the cover")
  func maskBlanksOnlyTheCorner() {
    let cover = Self.bitmap(Self.yellow) { _, _ in true }
    let masked = AudibleSash.masked(cover, width: Self.side, height: Self.side)
    var blanked = 0
    var mismatched = 0
    for row in 0..<Self.side {
      for column in 0..<Self.side {
        let offset = (row * Self.side + column) * 4
        let position =
          (Double(column) + 0.5) / Double(Self.side) + (Double(row) + 0.5) / Double(Self.side)
        let inCorner = position >= AudibleSash.maskStart
        if inCorner { blanked += 1 }
        let expected = inCorner ? [Float(0), 0, 0, 1] : Array(cover[offset..<offset + 4])
        if Array(masked[offset..<offset + 4]) != expected { mismatched += 1 }
      }
    }
    #expect(blanked > 0)
    #expect(mismatched == 0)
  }
}
