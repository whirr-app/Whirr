import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetStorageLayoutTests {
  private let container = URL(fileURLWithPath: "/containers/group", isDirectory: true)

  @Test func everyFileLivesUnderTheOneRemovableFolder() throws {
    let root = WidgetStorageLayout.rootDirectory(inContainer: container).standardizedFileURL.path
    #expect(root == "/containers/group/Widgets")
    for url in [
      WidgetStorageLayout.snapshotFile(inContainer: container),
      WidgetStorageLayout.coversDirectory(inContainer: container),
      try WidgetStorageLayout.coverFile(named: "abc-123.jpg", inContainer: container),
    ] {
      #expect(url.standardizedFileURL.path.hasPrefix(root + "/"))
    }
  }

  /// The extension opens covers by the name the snapshot gives, so a name that could leave the
  /// covers folder, or name another kind of file, is refused.
  @Test func coverNamesCannotEscapeTheCoversFolder() {
    for name in [
      "../snapshot.json", "../../x.jpg", "a/b.jpg", ".jpg", "x.jpeg", "x.JPG", "x.jpg.png",
      "a.b.jpg", "x .jpg", String(repeating: "a", count: 65) + ".jpg", "~.jpg",
    ] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetStorageLayout.coverFile(named: name, inContainer: container)
      }
    }
  }

  /// The release audit pins this group on the app and the extension; the two must agree.
  @Test func appGroupMatchesTheAuditedEntitlement() {
    #expect(WidgetStorageLayout.appGroupIdentifier == "group.com.remoteconcern.whirr")
  }
}
