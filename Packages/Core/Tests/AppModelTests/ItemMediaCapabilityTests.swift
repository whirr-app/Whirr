import Persistence
import Testing

@testable import AppModel

@Suite struct ItemMediaCapabilityTests {
  @Test("media capability separates PDF sidecars from readable EPUB editions")
  func capabilityMatrix() {
    #expect(
      ItemMediaCapability.derive(category: .audiobook, hasReadableEbook: false) == .audio)
    #expect(
      ItemMediaCapability.derive(category: .audiobook, hasReadableEbook: true)
        == .audioAndEbook)
    #expect(ItemMediaCapability.derive(category: .ebook, hasReadableEbook: true) == .ebook)
    #expect(
      ItemMediaCapability.derive(category: .ebook, hasReadableEbook: false)
        == .unsupportedDocument)
  }

  @Test("unsupported documents expose neither read nor download")
  func unsupportedDocumentHasNoActions() {
    let capability = ItemMediaCapability.unsupportedDocument
    #expect(capability.supportsReading == false)
    #expect(capability.supportsDownload == false)
  }

  /// Only a mixed item is offered a choice. Every other downloadable capability gets one format
  /// and a single Download row, since a submenu for one medium is a second tap for no decision.
  @Test(
    "download choices follow capability, and only a mixed item is asked",
    arguments: [
      (ItemMediaCapability.audio, [ItemDownloadFormat.audio]),
      (.ebook, [.ebook]),
      (.podcast, [.audio]),
      (.audioAndEbook, [.audio, .ebook, .both]),
      (.unsupportedDocument, []),
    ])
  func downloadFormatsFollowCapability(
    capability: ItemMediaCapability, expected: [ItemDownloadFormat]
  ) {
    #expect(capability.downloadFormats == expected)
    #expect(capability.downloadFormats.isEmpty == !capability.supportsDownload)
  }

  /// Only a mixed item is offered a format choice; every other downloadable capability downloads
  /// on one tap.
  @Test("only a mixed item asks which medium to download")
  func offersFormatChoiceFollowsTheDownloadFormats() {
    #expect(ItemMediaCapability.audioAndEbook.offersFormatChoice)
    for capability: ItemMediaCapability in [.audio, .ebook, .podcast, .unsupportedDocument] {
      #expect(capability.offersFormatChoice == false)
    }
  }

  @Test("a bulk download request resolves against what the item can actually fetch")
  func downloadFormatResolvesARequestAgainstCapability() {
    // No request: a sole format is taken, a mixed item needs an explicit choice.
    #expect(ItemMediaCapability.audio.downloadFormat(requested: nil) == .audio)
    #expect(ItemMediaCapability.ebook.downloadFormat(requested: nil) == .ebook)
    #expect(ItemMediaCapability.audioAndEbook.downloadFormat(requested: nil) == nil)

    // "Both" means every available format, without asking a single-medium item for another.
    #expect(ItemMediaCapability.audioAndEbook.downloadFormat(requested: .both) == .both)
    #expect(ItemMediaCapability.ebook.downloadFormat(requested: .both) == .ebook)
    #expect(ItemMediaCapability.podcast.downloadFormat(requested: .both) == .audio)

    // A specific format is honoured only when the item has it.
    #expect(ItemMediaCapability.audioAndEbook.downloadFormat(requested: .ebook) == .ebook)
    #expect(ItemMediaCapability.audio.downloadFormat(requested: .ebook) == nil)
    #expect(ItemMediaCapability.ebook.downloadFormat(requested: .audio) == nil)

    for requested in [nil, ItemDownloadFormat.audio, .ebook, .both] {
      #expect(ItemMediaCapability.unsupportedDocument.downloadFormat(requested: requested) == nil)
    }
  }
}
