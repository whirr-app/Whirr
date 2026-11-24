#if DEBUG
  import Foundation
  import Testing
  @testable import Whirr

  @MainActor
  @Suite struct PodcastFilesDevelopmentProbeTests {
    @Test func bookmarkSurvivesNewProbeAndCoordinatedReplacement() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let id = UUID()
      var starts = 0
      var stops = 0
      func probe() -> PodcastFilesDevelopmentProbe {
        PodcastFilesDevelopmentProbe(
          identifier: id,
          startAccess: { _ in
            starts += 1
            return true
          }, stopAccess: { _ in stops += 1 })
      }
      let first = Data("synthetic first generation".utf8)
      let second = Data("synthetic replacement".utf8)
      let receipt = try probe().create(in: folder, payload: first)
      _ = try probe().verify(bookmark: receipt.bookmark, expected: first)
      _ = try probe().replace(bookmark: receipt.bookmark, expectedPrevious: first, payload: second)
      _ = try probe().verify(bookmark: receipt.bookmark, expected: second)
      #expect(starts == 4)
      #expect(stops == starts)
    }

    @Test func rejectedWritesPreservePreviousSyntheticGeneration() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      var starts = 0
      var stops = 0
      let probe = PodcastFilesDevelopmentProbe(
        identifier: UUID(),
        startAccess: { _ in
          starts += 1
          return true
        }, stopAccess: { _ in stops += 1 })
      let first = Data("previous synthetic generation".utf8)
      let receipt = try probe.create(in: folder, payload: first)
      #expect(throws: PodcastFilesDevelopmentProbe.Failure.alreadyExists) {
        try probe.create(in: folder, payload: Data())
      }
      #expect(throws: PodcastFilesDevelopmentProbe.Failure.missingOrUnexpectedPayload) {
        try probe.replace(bookmark: receipt.bookmark, expectedPrevious: Data(), payload: Data())
      }
      #expect(throws: PodcastFilesDevelopmentProbe.Failure.tooLarge) {
        try probe.replace(
          bookmark: receipt.bookmark, expectedPrevious: first, payload: Data(repeating: 0, count: 65_537))
      }
      _ = try probe.verify(bookmark: receipt.bookmark, expected: first)
      #expect(starts == stops)
    }

    @Test func deniedScopeLeavesFolderEmpty() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      var stops = 0
      let probe = PodcastFilesDevelopmentProbe(
        identifier: UUID(), startAccess: { _ in false }, stopAccess: { _ in stops += 1 })
      #expect(throws: PodcastFilesDevelopmentProbe.Failure.scopeDenied) {
        try probe.create(in: folder, payload: Data("synthetic".utf8))
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
      #expect(stops == 0)
    }
  }
#endif
