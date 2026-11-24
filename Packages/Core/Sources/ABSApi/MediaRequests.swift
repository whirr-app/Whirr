import Foundation

/// Restricted media request value types, consumed by `CoverImageClient` and the App's
/// background-download adapter (ARCHITECTURE.md §2). Not a generic URL builder: each type is
/// constructible only for one fixed endpoint shape, and every id is a validated path component so
/// a hostile id can neither add an extra path segment nor escape the composed prefix. Fetching,
/// caching, resume and file writes live elsewhere.
public enum MediaRequestError: Error, Sendable, Equatable {
  case invalidItemID
  case invalidFileID
}

enum CoverImageLimits {
  /// Full-size cover art is allowed up to 20 MiB: enough for high-resolution artwork while
  /// preventing an unexpectedly large image response from consuming the general API budget.
  static let maximumResponseBytes = CoverImageAdmission.maximumResponseBytes
}

/// A single opaque path segment. RequestBuilder also rejects `?`/`#`/`..` segments, but a bare `/`
/// inside an interpolated id would add an extra path segment and redirect the request to a
/// different endpoint shape before RequestBuilder sees it, so the check has to happen here.
private func validatedPathSegment(_ value: String, otherwise error: MediaRequestError) throws -> String {
  guard isUsablePathSegment(value) else {
    throw error
  }
  return value
}

/// The encoding a cover is requested in. WebP is the default; watchOS cannot decode WebP, so the
/// Watch's own cover client asks for JPEG.
public enum CoverImageFormat: String, Sendable, Hashable {
  case webp
  case jpeg

  public var mimeType: String { "image/\(rawValue)" }
}

/// `GET /api/items/{id}/cover?width=<w>&format=webp` (API-CONVENTIONS.md rule 18). Unauthenticated:
/// cover GETs are exempt from auth on current servers (API-CONVENTIONS.md rule 2). This is the
/// only unauthenticated shape in v1. The server also exempts `.../authors/{id}/image`, so revisit
/// when author images are introduced.
public struct CoverRequest: Sendable, Equatable {
  public let itemID: String
  public let width: Int?
  /// Carried as `ts` so a replaced cover is a new URL, and therefore a new cache file, rather
  /// than the old bytes served forever. The server ignores it when choosing what to send.
  public let revision: ArtworkRevision
  public let format: CoverImageFormat

  /// The MIME type the caller should validate a default (`format=webp`) response against.
  public static let acceptedMIMETypes = ["image/webp"]

  /// Cover pixel widths at or above `highFidelityQuantizationFloor` round up to the next multiple
  /// of this step before reaching the URL/cache key, so high-fidelity surfaces share one entry per
  /// item.
  ///
  /// 256 is the smallest step at which item detail's 272pt hero and the expanded player's 380pt
  /// phone cap (shared by the lock screen) can share a width: on a 2x phone 544px and 760px both
  /// become 768 (at 128, 640 and 768). On a 3x phone no step merges 816px and 1140px, so detail
  /// fetches 1024 and the player 1280. Rounding is always up, so a request never gets fewer pixels
  /// than asked for.
  public static let widthQuantizationStep = 256

  /// Quantization applies only at or above this floor; smaller widths pass through. Quantizing the
  /// small, most-scrolled surfaces (browse and search rows, mini-player, Home card) would inflate
  /// them for no sharing and make the cover cache evict their thumbnails. The floor must sit above
  /// the largest small-surface request (Home card at 3x, 420px) and at or below the smallest
  /// high-fidelity one (item detail at 2x, 544px); `2 * widthQuantizationStep` (512) does. A
  /// request on the floor is unchanged; 513 rounds up to 768.
  public static let highFidelityQuantizationFloor = 2 * widthQuantizationStep

  /// Rounds `pixelWidth` up to the next multiple of `widthQuantizationStep`, but only once it is
  /// at or above `highFidelityQuantizationFloor`; anything below the floor (including non-positive
  /// input) is returned unchanged.
  public static func quantizedWidth(_ pixelWidth: Int) -> Int {
    guard pixelWidth >= highFidelityQuantizationFloor else { return pixelWidth }
    let step = widthQuantizationStep
    return ((pixelWidth + step - 1) / step) * step
  }

  public init(
    itemID: String, width: Int? = nil, revision: ArtworkRevision = .unversioned, format: CoverImageFormat = .webp
  ) throws {
    self.itemID = try validatedPathSegment(itemID, otherwise: .invalidItemID)
    self.width = width.map(Self.quantizedWidth)
    self.revision = revision
    self.format = format
  }

  /// A width sent as given, with no quantization. Only the aspect-fitted detail cover uses it: its
  /// width is chosen per cover, so no other surface shares a step with it, and rounding 660 up to
  /// 768 would give back the bytes the fitting saved.
  public init(
    itemID: String, exactWidth: Int, revision: ArtworkRevision = .unversioned,
    format: CoverImageFormat = .webp
  ) throws {
    self.itemID = try validatedPathSegment(itemID, otherwise: .invalidItemID)
    width = exactWidth
    self.revision = revision
    self.format = format
  }

  /// Takes no `bearerToken` parameter: cover requests are unauthenticated.
  public func makeRequest(using requestBuilder: RequestBuilder) throws -> HTTPRequest {
    var queryItems = [URLQueryItem(name: "format", value: format.rawValue)]
    if let width {
      queryItems.append(URLQueryItem(name: "width", value: String(width)))
    }
    if revision != .unversioned {
      queryItems.append(URLQueryItem(name: "ts", value: revision.rawValue))
    }
    return try requestBuilder.makeRequest(
      method: .get,
      path: "/api/items/\(itemID)/cover",
      queryItems: queryItems,
      acceptedMIMETypes: [format.mimeType],
      routeTemplate: "/api/items/:id/cover",
      transportClass: .coverArtwork,
      maximumResponseBytes: CoverImageAdmission.maximumResponseBytes
    )
  }
}

/// `GET /api/items/{id}/file/{fileid}/download` (API-CONVENTIONS.md rule 24: per-file download via
/// a background `URLSession`, supports Range/resume). Authorised by a Bearer header attached when
/// the request is built, never a `?token=` query parameter (rule 2), so the App's
/// background-download adapter (ARCHITECTURE.md §2) can execute an already-authorised request
/// without ever holding the refresh token.
public struct FileDownloadRequest: Sendable, Equatable {
  public let itemID: String
  public let fileID: String
  public let range: String?
  /// The audio file's known MIME type (from the item detail's `audioFiles[].mimeType`). Audio
  /// formats vary per file, so this cannot be a fixed constant like `CoverRequest`'s.
  public let expectedMIMEType: String
  /// The audio file's known byte size (from `AudioFileCatalog`/`AudioFileInfo`). Carried through
  /// so the download adapter can verify a completed transfer; it does not shape the request.
  public let expectedSize: Int

  public init(
    itemID: String,
    fileID: String,
    expectedMIMEType: String,
    expectedSize: Int,
    range: String? = nil
  ) throws {
    self.itemID = try validatedPathSegment(itemID, otherwise: .invalidItemID)
    self.fileID = try validatedPathSegment(fileID, otherwise: .invalidFileID)
    self.expectedMIMEType = expectedMIMEType
    self.expectedSize = expectedSize
    self.range = range
  }

  public func makeRequest(using requestBuilder: RequestBuilder, accessToken: String) throws -> HTTPRequest {
    var headers: [String: String] = [:]
    if let range {
      // Carried through untouched: the adapter owns resume semantics, this type only preserves it.
      headers["Range"] = range
    }
    return try requestBuilder.makeRequest(
      method: .get,
      path: "/api/items/\(itemID)/file/\(fileID)/download",
      headers: headers,
      acceptedMIMETypes: [expectedMIMEType],
      bearerToken: accessToken,
      routeTemplate: "/api/items/:id/file/:fileid/download",
      transportClass: .download
    )
  }
}

/// `GET /api/items/{id}/ebook` (API-CONVENTIONS.md rule 24). v1 is EPUB only, matching rule 24's
/// stated shape; other `ebookFormat` values are unsupported until their handling is verified.
public struct EbookRequest: Sendable, Equatable {
  public let itemID: String

  public static let acceptedMIMETypes = ["application/epub+zip"]

  public init(itemID: String) throws {
    self.itemID = try validatedPathSegment(itemID, otherwise: .invalidItemID)
  }

  public func makeRequest(using requestBuilder: RequestBuilder, accessToken: String) throws -> HTTPRequest {
    try requestBuilder.makeRequest(
      method: .get,
      path: "/api/items/\(itemID)/ebook",
      acceptedMIMETypes: Self.acceptedMIMETypes,
      bearerToken: accessToken,
      routeTemplate: "/api/items/:id/ebook",
      transportClass: .download
    )
  }
}
