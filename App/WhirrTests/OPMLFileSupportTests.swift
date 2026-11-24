import Testing
import UniformTypeIdentifiers

@testable import Whirr

@Suite("OPML file support")
struct OPMLFileSupportTests {
  @Test("the importer uses system type matching without a declared custom document type")
  func systemTypesOnly() {
    #expect(OPMLFileSupport.allowedContentTypes.contains(.xml))
    #expect(
      OPMLFileSupport.allowedContentTypes.contains {
        $0 == UTType(filenameExtension: "opml")
      })
  }
}
