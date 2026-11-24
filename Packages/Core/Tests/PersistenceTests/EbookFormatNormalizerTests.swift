import Testing

@testable import Persistence

@Suite struct EbookFormatNormalizerTests {
  @Test("normalization trims, lowercases, and removes every leading dot")
  func normalizeEbookFormat() {
    #expect(EbookFormatNormalizer.normalize("  ..EPUB  ") == "epub")
    #expect(EbookFormatNormalizer.normalize("   ") == nil)
    #expect(EbookFormatNormalizer.normalize(nil) == nil)
  }
}
