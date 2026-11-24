import Testing

@testable import AppModel

/// The Downloads row and the clear confirmation both quote the same figure, so it is derived
/// rather than formatted at each call site, as `StorageCopy` does for byte totals.
@Suite("ArtworkCacheCopy")
struct ArtworkCacheCopyTests {
  @Test("a measured size is quoted as bytes")
  func sizeDetailQuotesBytes() {
    #expect(
      SettingsCopy.artworkCacheSizeDetail(bytes: 214 * 1000 * 1000) == "214 MB")
  }

  @Test("an unmeasured size uses the placeholder rather than zero")
  func unmeasuredSizeUsesPlaceholder() {
    #expect(SettingsCopy.artworkCacheSizeDetail(bytes: nil) == "—")
  }

  @Test("the clear confirmation says it frees bytes, refills, repairs, and keeps the server copy")
  func clearMessageStatesTheConsequences() {
    let message = SettingsCopy.artworkCacheClearArtworkMessage(bytes: 214 * 1000 * 1000)

    #expect(message.contains("214 MB"))
    #expect(message.localizedCaseInsensitiveContains("refill"))
    #expect(message.localizedCaseInsensitiveContains("stuck or incorrect"))
    #expect(message.localizedCaseInsensitiveContains("server"))
  }
}
