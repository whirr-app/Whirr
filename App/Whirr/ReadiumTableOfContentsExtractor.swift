import Foundation
import ReaderCore
import ReadiumShared
import ReadiumStreamer

/// Reads a local EPUB's navigation document and nothing else.
///
/// Has its own `AssetRetriever`/`PublicationOpener`, not shared with `ReadiumEPUBRenderer`, so the
/// detail screen can never close the reader's live publication. The table of contents comes off
/// the parsed `Publication`, needing no navigator, UIKit host or lifecycle state machine.
@MainActor
final class ReadiumTableOfContentsExtractor: EPUBTableOfContentsReading {
  private lazy var httpClient = DefaultHTTPClient(ephemeral: true)
  private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
  private lazy var parser = DefaultPublicationParser(
    httpClient: httpClient,
    assetRetriever: assetRetriever,
    pdfFactory: DefaultPDFDocumentFactory()
  )
  private lazy var opener = PublicationOpener(parser: parser)

  func tableOfContents(localFileURL: URL) async throws -> [TOCEntry] {
    if let failure = ReadiumEPUBRenderer.localFileFailure(for: localFileURL) {
      throw failure
    }
    guard let fileURL = FileURL(url: localFileURL) else {
      throw EPUBRenderingOpenFailure.noEbook
    }

    let asset: Asset
    switch await assetRetriever.retrieve(url: fileURL) {
    case .success(let value):
      asset = value
    case .failure(let error):
      throw ReadiumEPUBRenderer.classifyOpenFailure(error)
    }
    guard asset.format.conformsTo(.epub) else {
      throw EPUBRenderingOpenFailure.unopenable
    }

    let publication: Publication
    switch await opener.open(asset: asset, allowUserInteraction: false) {
    case .success(let value):
      publication = value
    case .failure(let error):
      throw ReadiumEPUBRenderer.classifyOpenFailure(error)
    }

    // The positions list is what gives each entry its `startProgression`, and it is the only
    // reason this reads more than the navigation document. Readium derives it from the resources'
    // own lengths, so a failure here costs read marks, not the contents list.
    let progressionsByResourceHref: [String: Double]
    switch await publication.positions() {
    case .success(let locators):
      progressionsByResourceHref = ReadiumEPUBRenderer.startProgressionByResourceHref(
        locators.compactMap(ReadiumEPUBRenderer.readingPosition(from:)))
    case .failure:
      progressionsByResourceHref = [:]
    }

    switch await publication.tableOfContents() {
    case .success(let links):
      return ReadiumEPUBRenderer.flattenTOC(
        links, progressionsByResourceHref: progressionsByResourceHref)
    case .failure:
      throw EPUBRenderingOpenFailure.unopenable
    }
  }
}
