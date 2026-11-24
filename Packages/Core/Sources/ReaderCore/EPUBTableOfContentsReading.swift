import Foundation

/// Reads an EPUB's table of contents without rendering it.
///
/// Separate from `EPUBRendering`: the production adapter opens the asset, reads the navigation
/// document and discards it, never building a navigator or touching the live renderer. A detail
/// screen sharing the reader's renderer would close the shared publication when SwiftUI discarded
/// a rebuilt model, blanking the reading page.
///
/// Failures reuse `EPUBRenderingOpenFailure` (missing file, DRM, unparseable).
public protocol EPUBTableOfContentsReading: Sendable {
  /// Flattened, depth-annotated entries for the publication at `localFileURL`. An empty array is
  /// a real result: a publication may legitimately ship no navigation document, and that stays
  /// distinct from a thrown failure to open it.
  func tableOfContents(localFileURL: URL) async throws -> [TOCEntry]
}

/// Default conformance for callers with no concrete extractor composed. Always throws `noEbook`,
/// so the Contents tab resolves to its unavailable state.
public struct NoOpEPUBTableOfContentsReading: EPUBTableOfContentsReading, Sendable {
  public init() {}

  public func tableOfContents(localFileURL: URL) async throws -> [TOCEntry] {
    throw EPUBRenderingOpenFailure.noEbook
  }
}
