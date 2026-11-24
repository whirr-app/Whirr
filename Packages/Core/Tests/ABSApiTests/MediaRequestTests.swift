import Foundation
import Testing

@testable import ABSApi

@Suite("Media requests")
struct MediaRequestTests {
  private func makeRequestBuilder(pathPrefix: String = "/abs") throws -> RequestBuilder {
    let config = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test\(pathPrefix)/"))
    )
    return RequestBuilder(server: config)
  }

  // MARK: - CoverRequest

  @Test("builds a path-prefix-safe, unauthenticated cover URL with width and format=webp")
  func coverRequestBuildsExpectedURL() throws {
    let builder = try makeRequestBuilder()
    // 400 is below the high-fidelity quantization floor, so it passes through untouched and
    // the URL carries the requested width.
    let cover = try CoverRequest(itemID: "item-1", width: 400)
    let request = try cover.makeRequest(using: builder)

    #expect(request.method == .get)
    #expect(
      request.url.absoluteString
        == "https://books.example.test/abs/api/items/item-1/cover?format=webp&width=400")
    #expect(request.headers["Authorization"] == nil)
    #expect(CoverRequest.acceptedMIMETypes == ["image/webp"])
    #expect(request.headers["Accept"] == "image/webp")
  }

  @Test("a JPEG cover request asks for format=jpeg and accepts image/jpeg")
  func jpegCoverRequestBuildsExpectedURL() throws {
    let builder = try makeRequestBuilder()
    let cover = try CoverRequest(itemID: "item-1", width: 96, format: .jpeg)
    let request = try cover.makeRequest(using: builder)

    #expect(
      request.url.absoluteString
        == "https://books.example.test/abs/api/items/item-1/cover?format=jpeg&width=96")
    #expect(request.headers["Accept"] == "image/jpeg")
    #expect(try CoverRequest(itemID: "item-1").format == .webp)
  }

  @Test("cover requests use the dedicated artwork transport budget")
  func coverRequestUsesArtworkTransportClass() throws {
    let builder = try makeRequestBuilder()
    let request = try CoverRequest(itemID: "item-1", width: 280).makeRequest(using: builder)

    // A cover is a server-side resize, not an ordinary API call. It must not share the API
    // pool's 15-second inactivity budget, which strands the slowest covers on a blank tile.
    #expect(request.transportClass == .coverArtwork)
    #expect(request.timeout == HTTPTransportClass.coverArtwork.requestTimeout)
  }

  @Test("omits the width query item when no width is requested")
  func coverRequestOmitsWidthWhenNil() throws {
    let builder = try makeRequestBuilder()
    let cover = try CoverRequest(itemID: "item-1")
    let request = try cover.makeRequest(using: builder)

    #expect(request.url.query?.contains("width") == false)
    #expect(request.url.query == "format=webp")
  }

  @Test("a server revision is carried as ts so a replaced cover is a distinct URL")
  func coverRequestCarriesRevisionAsTimestamp() throws {
    let builder = try makeRequestBuilder()
    let cover = try CoverRequest(
      itemID: "item-1", width: 400, revision: ArtworkRevision("1700000000000"))
    let request = try cover.makeRequest(using: builder)

    #expect(
      request.url.absoluteString
        == "https://books.example.test/abs/api/items/item-1/cover?format=webp&width=400&ts=1700000000000")
  }

  @Test("an unversioned cover request carries no ts")
  func unversionedCoverRequestOmitsTimestamp() throws {
    let builder = try makeRequestBuilder()
    let cover = try CoverRequest(itemID: "item-1", width: 400, revision: .unversioned)
    let request = try cover.makeRequest(using: builder)

    #expect(request.url.query == "format=webp&width=400")
  }

  @Test("rejects hostile cover item ids")
  func coverRequestRejectsHostileIDs() throws {
    for hostileID in ["../etc", "..", ".", "a/b", "a?b=1", "a#frag", ""] {
      #expect(throws: MediaRequestError.self) {
        try CoverRequest(itemID: hostileID)
      }
    }
  }

  @Test("accepts the reserved-looking RSS id as a valid cover path segment")
  func coverRequestAcceptsRSSNamespaceID() throws {
    // `:` is permitted in a path segment, so namespace reservation belongs to ingest/routing,
    // not to structural path validation in ABSApi.
    let cover = try CoverRequest(itemID: "rss:42")
    #expect(cover.itemID == "rss:42")
  }

  // MARK: - CoverRequest width quantization

  @Test("quantizes the requested pixel width up to the next step, at or above the high-fidelity floor")
  func coverWidthQuantizesUpToTheNextStep() throws {
    // (requested pixel width, expected width). Includes the six surfaces' real values at 2x/3x,
    // a value already on a step boundary (unchanged), and Now Playing's flat 600px. The small
    // surfaces (thumbnails, Home card) sit below `highFidelityQuantizationFloor` and must pass
    // through untouched; see `thumbnailWidthsAreNotQuantized`.
    let cases: [(requested: Int, expected: Int)] = [
      (44 * 2, 44 * 2),  // thumbnails (browse row / search row / mini-player) at 2x, untouched
      (44 * 3, 44 * 3),  // thumbnails at 3x, untouched
      (140 * 2, 140 * 2),  // Home card at 2x, untouched
      (140 * 3, 140 * 3),  // Home card at 3x, untouched
      (272 * 2, 768),  // item detail hero at 2x, first high-fidelity surface, quantized
      (272 * 3, 1024),  // item detail hero at 3x
      (600, 768),  // Now Playing's flat 600px (not pt × scale)
      (256, 256),  // below the floor: unchanged (also already a step multiple)
      (512, 512),  // exactly the floor, exactly on a step: unchanged
    ]

    for testCase in cases {
      let cover = try CoverRequest(itemID: "item-1", width: testCase.requested)
      #expect(
        cover.width == testCase.expected,
        "requested \(testCase.requested) expected \(testCase.expected), got \(String(describing: cover.width))"
      )
    }
  }

  @Test("the quantized width never shrinks the request: output is always >= input")
  func quantizedWidthNeverShrinksTheRequest() throws {
    for requested in [1, 44 * 2, 44 * 3, 140 * 2, 140 * 3, 272 * 2, 272 * 3, 600, 760, 954, 256, 4_096] {
      let cover = try CoverRequest(itemID: "item-1", width: requested)
      let quantized = try #require(cover.width)
      #expect(quantized >= requested)
    }
  }

  @Test("nil width (unspecified/full-size cover) is left alone, never quantized to a number")
  func nilWidthStaysNil() throws {
    let cover = try CoverRequest(itemID: "item-1")
    #expect(cover.width == nil)
  }

  @Test("small-surface (thumbnail/Home card) widths are never quantized: they stay exactly what was requested")
  func thumbnailWidthsAreNotQuantized() throws {
    // The real values from the app's small surfaces (library browse row, search row, mini-player
    // at 44pt; Home card at 140pt), at both 2x and 3x. Quantizing these would inflate the
    // most-scrolled surfaces' download size for no benefit.
    let untouchedWidths = [44 * 2, 44 * 3, 140 * 2, 140 * 3]

    for width in untouchedWidths {
      let cover = try CoverRequest(itemID: "item-1", width: width)
      #expect(
        cover.width == width, "expected \(width) to pass through untouched, got \(String(describing: cover.width))")
    }
  }

  @Test("quantization applies only at or above the high-fidelity floor")
  func quantizationAppliesOnlyAtOrAboveTheHighFidelityFloor() throws {
    let floor = CoverRequest.highFidelityQuantizationFloor

    // Just below the floor: passes through untouched, even though it is not on a step boundary.
    let justBelow = try CoverRequest(itemID: "item-1", width: floor - 1)
    #expect(justBelow.width == floor - 1)

    // At the floor: quantization applies (the floor is inclusive), but the floor is already a
    // step multiple, so the value is unchanged.
    let atFloor = try CoverRequest(itemID: "item-1", width: floor)
    #expect(atFloor.width == floor)

    // Between the floor and the first step boundary above it: rounds up to that boundary like
    // any other in-range value. The floor only gates whether quantization runs.
    let betweenFloorAndFirstStep = try CoverRequest(itemID: "item-1", width: floor + 1)
    #expect(betweenFloorAndFirstStep.width == floor + CoverRequest.widthQuantizationStep)
  }

  @Test(
    "item detail and the expanded player share one quantized width on the baseline device (2x iPad, portrait)"
  )
  func detailAndExpandedPlayerShareOneQuantizedWidthOnTheBaselineDevice() throws {
    // Baseline: any 2x iPad in portrait with the expanded player full-bleed. On iPad-class
    // screens `availableCoverWidth` and `proxy.size.height * 0.42` both clear 380pt, so
    // `ExpandedPlayerView` saturates at its `maximumCoverSize` of 380pt whatever the safe-area
    // insets. Item detail's hero is a fixed 272pt. Both are `pt × displayScale`; at 2x that's
    // detail 544px and the expanded player 760px.
    let detailPixelWidth = 272 * 2
    let expandedPlayerPixelWidth = 380 * 2  // capped at maximumCoverSize on this baseline device

    let detailRequest = try CoverRequest(itemID: "item-1", width: detailPixelWidth)
    let expandedPlayerRequest = try CoverRequest(itemID: "item-1", width: expandedPlayerPixelWidth)

    #expect(detailRequest.width == expandedPlayerRequest.width)
  }

  // MARK: - FileDownloadRequest

  @Test("builds an authorized per-file download request with no token in the URL")
  func fileDownloadRequestIsAuthorizedWithoutURLCredentials() throws {
    let builder = try makeRequestBuilder()
    let download = try FileDownloadRequest(
      itemID: "item-1",
      fileID: "file-9",
      expectedMIMEType: "audio/mpeg",
      expectedSize: 123_456
    )
    let request = try download.makeRequest(using: builder, accessToken: "secret-access-token")

    #expect(
      request.url.absoluteString == "https://books.example.test/abs/api/items/item-1/file/file-9/download")
    #expect(request.headers["Authorization"] == "Bearer secret-access-token")
    #expect(request.url.absoluteString.contains("secret-access-token") == false)
    #expect(request.url.query == nil)
    #expect(download.expectedMIMEType == "audio/mpeg")
    #expect(download.expectedSize == 123_456)
    #expect(request.headers["Accept"] == "audio/mpeg")
  }

  @Test("preserves an explicit Range header untouched")
  func fileDownloadRequestPreservesRange() throws {
    let builder = try makeRequestBuilder()
    let download = try FileDownloadRequest(
      itemID: "item-1",
      fileID: "file-9",
      expectedMIMEType: "audio/mpeg",
      expectedSize: 100,
      range: "bytes=100-199"
    )
    let request = try download.makeRequest(using: builder, accessToken: "token")

    #expect(request.headers["Range"] == "bytes=100-199")
  }

  @Test("omits the Range header when no range is requested")
  func fileDownloadRequestOmitsRangeWhenNil() throws {
    let builder = try makeRequestBuilder()
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "file-9", expectedMIMEType: "audio/mpeg", expectedSize: 100
    )
    let request = try download.makeRequest(using: builder, accessToken: "token")

    #expect(request.headers["Range"] == nil)
  }

  @Test("rejects hostile file download ids")
  func fileDownloadRequestRejectsHostileIDs() throws {
    for hostileID in ["../etc", "..", ".", "a/b", "a?b=1", "a#frag", ""] {
      #expect(throws: MediaRequestError.self) {
        try FileDownloadRequest(itemID: hostileID, fileID: "file-9", expectedMIMEType: "audio/mpeg", expectedSize: 100)
      }
      #expect(throws: MediaRequestError.self) {
        try FileDownloadRequest(itemID: "item-1", fileID: hostileID, expectedMIMEType: "audio/mpeg", expectedSize: 100)
      }
    }
  }

  // MARK: - EbookRequest

  @Test("builds an authorized ebook request with no token in the URL")
  func ebookRequestIsAuthorizedWithoutURLCredentials() throws {
    let builder = try makeRequestBuilder()
    let ebook = try EbookRequest(itemID: "item-1")
    let request = try ebook.makeRequest(using: builder, accessToken: "secret-access-token")

    #expect(request.url.absoluteString == "https://books.example.test/abs/api/items/item-1/ebook")
    #expect(request.headers["Authorization"] == "Bearer secret-access-token")
    #expect(request.url.absoluteString.contains("secret-access-token") == false)
    #expect(request.url.query == nil)
    #expect(EbookRequest.acceptedMIMETypes == ["application/epub+zip"])
    #expect(request.headers["Accept"] == "application/epub+zip")
  }

  @Test("rejects hostile ebook item ids")
  func ebookRequestRejectsHostileIDs() throws {
    for hostileID in ["../etc", "..", ".", "a/b", "a?b=1", "a#frag", ""] {
      #expect(throws: MediaRequestError.self) {
        try EbookRequest(itemID: hostileID)
      }
    }
  }

  // MARK: - Path-prefix safety (shared across request types)

  @Test("keeps every media request inside the configured path prefix")
  func requestsStayInsidePathPrefix() throws {
    let builder = try makeRequestBuilder(pathPrefix: "/nested/abs")

    let coverRequest = try CoverRequest(itemID: "item-1").makeRequest(using: builder)
    #expect(coverRequest.url.path.hasPrefix("/nested/abs/api/items/"))

    let downloadRequest = try FileDownloadRequest(
      itemID: "item-1",
      fileID: "file-9",
      expectedMIMEType: "audio/mpeg",
      expectedSize: 100
    ).makeRequest(using: builder, accessToken: "token")
    #expect(downloadRequest.url.path.hasPrefix("/nested/abs/api/items/"))

    let ebookRequest = try EbookRequest(itemID: "item-1").makeRequest(using: builder, accessToken: "token")
    #expect(ebookRequest.url.path.hasPrefix("/nested/abs/api/items/"))
  }
}
