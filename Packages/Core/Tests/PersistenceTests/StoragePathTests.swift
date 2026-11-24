import Foundation
import Testing

@testable import Persistence

/// Pure containment maths shared by every download removal site. No filesystem is touched.
@Suite struct StoragePathTests {

  @Test func relativePathIsComputedStrictlyBelowTheRoot() {
    let root = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    #expect(
      StoragePath.relativePath(
        of: URL(fileURLWithPath: "/tmp/downloads/1/2/file.m4b"), under: root) == "1/2/file.m4b")
    #expect(StoragePath.relativePath(of: root, under: root) == nil)
    #expect(StoragePath.relativePath(of: URL(fileURLWithPath: "/tmp/downloads-evil/x"), under: root) == nil)
    #expect(StoragePath.relativePath(of: URL(fileURLWithPath: "/tmp/elsewhere/x"), under: root) == nil)
  }

  @Test func aRelativePathInsideTheRootIsContained() {
    let root = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    #expect(StoragePath.isContained(relativePath: "1/2/file.m4b", under: root))
    #expect(StoragePath.isContained(relativePath: "RSS/7/9.mp3", under: root))
  }

  @Test func traversalAndAbsolutePathsAreNeverContained() {
    let root = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    #expect(StoragePath.isContained(relativePath: "../escape.m4b", under: root) == false)
    #expect(StoragePath.isContained(relativePath: "1/../../escape.m4b", under: root) == false)
    #expect(StoragePath.isContained(relativePath: "1/..", under: root) == false)
    #expect(StoragePath.isContained(relativePath: "/tmp/escape.m4b", under: root) == false)
    #expect(StoragePath.isContained(relativePath: "", under: root) == false)
  }

  @Test func aSiblingDirectorySharingTheRootPrefixIsNotContained() {
    let root = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    #expect(StoragePath.isContained(relativePath: "../downloads-evil/x", under: root) == false)
  }

  @Test func theRssRootRejectsItsOwnDirectoryAndTheAbsTree() {
    let root = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
    let rssRoot = root.appendingPathComponent(RSSFileRoot.directoryName, isDirectory: true)

    #expect(StoragePath.isContained(relativePath: "7/9.mp3", under: rssRoot))
    #expect(StoragePath.isContained(relativePath: "", under: rssRoot) == false)
    #expect(StoragePath.isContained(relativePath: "../1/abs.m4b", under: rssRoot) == false)
  }
}
