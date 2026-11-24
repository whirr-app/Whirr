import SwiftUI

/// Deterministic stand-in artwork for items the server has no cover for, laid out like a
/// mid-century paperback classic: two orange colour bands with a cream panel of serif type
/// between them. Every generated cover uses the same orange treatment across launches, screens,
/// and devices.
public struct GeneratedCoverArt: Sendable, Equatable {
  public let displayTitle: String
  public let displayAuthor: String?
  public let seed: String
  public let palette: GeneratedCoverPalette

  public init(title: String, author: String? = nil) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)
    let author = (trimmedAuthor?.isEmpty == false) ? trimmedAuthor : nil

    displayAuthor = author
    seed = author.map { "\(trimmedTitle) — \($0)" } ?? trimmedTitle
    palette = .orange
    displayTitle = Self.mainTitle(of: trimmedTitle)
  }

  /// Library titles routinely carry the subtitle inline ("A Christmas Carol: A Ghost Story of
  /// Christmas"). The band panel only has room for the work itself.
  private static func mainTitle(of title: String) -> String {
    guard let separator = title.firstIndex(of: ":") else { return title }
    let head = title[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    return head.isEmpty ? title : head
  }
}

/// The fixed band colour for generated paperback-style covers.
public enum GeneratedCoverPalette: Sendable {
  case orange

  public var band: Color { Color(red: 0.85, green: 0.36, blue: 0.13) }

  /// Cream stock rather than white, which reads as "missing image" next to real covers.
  public var paper: Color { Color(red: 0.95, green: 0.93, blue: 0.87) }

  public var ink: Color { Color(red: 0.11, green: 0.10, blue: 0.09) }
}

/// Draws a `GeneratedCoverArt`. Metrics are proportional to the rendered width so the same
/// view reads correctly as a 44pt list thumbnail and as a full-width player cover; the finer
/// details (author, rules) drop away once they would be illegible.
public struct GeneratedCoverArtView: View {
  let art: GeneratedCoverArt

  public init(art: GeneratedCoverArt) {
    self.art = art
  }

  public init(title: String, author: String? = nil) {
    self.init(art: GeneratedCoverArt(title: title, author: author))
  }

  public var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let bandHeight = proxy.size.height * 0.235
      let showsDetail = width >= 88

      VStack(spacing: 0) {
        art.palette.band.frame(height: bandHeight)
        panel(width: width, showsDetail: showsDetail)
        art.palette.band.frame(height: bandHeight)
      }
      .background(art.palette.paper)
    }
    .aspectRatio(1, contentMode: .fill)
    .clipped()
  }

  private func panel(width: CGFloat, showsDetail: Bool) -> some View {
    VStack(spacing: width * 0.045) {
      Spacer(minLength: 0)

      Text(art.displayTitle.uppercased())
        .font(.system(size: width * 0.115, weight: .semibold, design: .serif))
        .tracking(width * 0.006)
        .foregroundStyle(art.palette.ink)
        .multilineTextAlignment(.center)
        .lineLimit(showsDetail ? 3 : 2)
        .minimumScaleFactor(0.5)

      if showsDetail, let author = art.displayAuthor {
        Rectangle()
          .fill(art.palette.ink.opacity(0.55))
          .frame(width: width * 0.22, height: max(1 / 3, width * 0.004))

        Text(author)
          .font(.system(size: width * 0.075, design: .serif))
          .italic()
          .foregroundStyle(art.palette.ink.opacity(0.8))
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, width * 0.09)
    .background(art.palette.paper)
  }
}
