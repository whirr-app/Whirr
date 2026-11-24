import AppModel
import DesignSystem
import Foundation
import PlayerCore
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// These composition rules are source-level gates. SwiftUI's rendered modifier tree is not a
/// stable semantic value, while observation boundaries and layout ownership are deliberate facts
/// about how these views are written.
@Suite("Seek feedback source scans")
struct SeekFeedbackSourceScanTests {
  // ExpandedPlayerView owns one feedback reference, PlayerChromeRegion passes it to both leaves,
  // TransportRow writes without observing, and only PlaybackTimelineSection reads the qualified
  // delta so per-tick feedback redraw remains confined to the timeline leaf.
  @Test("the timeline leaf is the only skip-feedback observer")
  func redrawBoundaryKeepsSkipFeedbackInTheTimelineLeaf() throws {
    let rootText = try ViewSourceScan.executableText(ofViewNamed: "ExpandedPlayerView")
    let chrome = try ViewSourceScan.source(named: "PlayerChromeRegion.swift")
    let transport = try ViewSourceScan.source(named: "TransportRow.swift")
    let chromeText = try ViewSourceScan.executableText(of: chrome)
    let transportText = try ViewSourceScan.executableText(of: transport)
    let intentsText = try ViewSourceScan.executableText(
      of: ViewSourceScan.source(named: "PlayerTransportIntents.swift"))

    #expect(
      ViewSourceScan.occurrences(of: ["SeekFeedbackState()"], in: rootText) == 1,
      "The expanded player must construct one reference-scoped feedback state so skip updates can cross leaves without making the page root observe them."
    )
    // Counted rather than matched against whole argument lines: the guarantee is that both leaves
    // receive the same reference, which a reformatting of either call site must not be able to fail.
    // The root now hands that one reference to `PlayerChromeRegion`, which composes both leaves,
    // and to the shared transport intents its keyboard shortcuts drive.
    #expect(
      ViewSourceScan.occurrences(of: ["seekFeedback: seekFeedback"], in: rootText) == 2,
      "The expanded player must pass its stable feedback reference both to the chrome region that composes the timeline and transport leaves, and to the shared transport intents behind its keyboard shortcuts."
    )
    #expect(
      ViewSourceScan.occurrences(of: ["seekFeedback: seekFeedback"], in: chromeText) == 2,
      "The chrome region must pass that same reference to both the timeline leaf and transport; otherwise the leaf cannot own the feedback observation and transport cannot write to it."
    )
    #expect(
      chromeText.contains("skipDeltaSeconds") == false,
      "PlayerChromeRegion must not read skipDeltaSeconds: a per-tick feedback read there would redraw all three controls instead of the timeline leaf alone."
    )
    #expect(
      rootText.contains("skipDeltaSeconds") == false,
      "The expanded player root must not read skipDeltaSeconds: a per-tick feedback read would redraw the cover, shadow, and ambient page hierarchy."
    )
    #expect(
      transportText.contains("skipDeltaSeconds") == false,
      "TransportRow must only write skip feedback through recordSkip; reading skipDeltaSeconds would make the transport observe the timeline's per-tick feedback state."
    )
    #expect(
      ViewSourceScan.occurrences(of: ["intents.skip("], in: transportText) == 2,
      "Both transport skip actions must retain their write-only skip path so the redraw boundary is not bypassed."
    )
    #expect(
      ViewSourceScan.occurrences(of: ["recordSkip("], in: intentsText) == 1,
      "The shared transport intents must be the one place a skip records feedback, and only a write."
    )
    #expect(
      intentsText.contains("skipDeltaSeconds") == false,
      "PlayerTransportIntents must only write skip feedback through recordSkip; reading skipDeltaSeconds would make every transport surface observe the timeline's feedback state."
    )

    let readers = try ViewSourceScan.appSources().filter { source in
      let text = try ViewSourceScan.executableText(of: source)
      // The state owner's declaration and internal writes are not observation dependencies. The
      // qualified member access is the source-level shape that SwiftUI observes in a view body.
      return ViewSourceScan.occurrences(of: ["seekFeedback.skipDeltaSeconds"], in: text) > 0
    }.map(\.lastPathComponent).sorted()
    #expect(
      readers == ["PlaybackTimelineSection.swift"],
      "Only PlaybackTimelineSection may read seekFeedback.skipDeltaSeconds; scanning the qualified member access keeps the sole observation dependency in that leaf while ignoring the state owner's declaration and internal writes."
    )
  }

  @MainActor
  @Test("the feedback bubble does not reserve scrubber height")
  func bubbleDoesNotChangeTheScrubberFrame() async throws {
    let harness = UIHarnessSession()
    let feedback = SeekFeedbackState(expire: { _, _ in Task {} })
    let identity = SeekFeedbackState.Identity(itemID: "seek-layout-item", episodeID: nil)
    let bounds = CGRect(x: 0, y: 0, width: 393, height: 240)

    let frames = try await withKeyWindow(bounds: bounds) { scope in
      PlayerLayoutProbe.reset()
      let hostingController = scope.host(
        HostedPlayerChrome(
          playback: harness.playback,
          player: harness.player,
          playbackRate: harness.playbackRate,
          seekFeedback: feedback))
      let withoutBubble = try await Self.settledScrubberFrame(
        in: scope.window, hostingController: hostingController)

      feedback.recordSkip(delta: 30, identity: identity)
      let withBubble = try await Self.settledScrubberFrame(
        in: scope.window, hostingController: hostingController)
      return (withoutBubble, withBubble)
    }

    #expect(
      frames.0.equalTo(frames.1),
      "scrubber frame changed when the feedback bubble became visible: without=\(frames.0) with=\(frames.1)"
    )
  }

  // PlaybackTimelineSection has exactly one expandedScrubber accessibility surface, and the
  // visual-only feedback overlay must not add another accessibility element.
  @Test("the existing scrubber remains the only accessibility surface")
  func scrubberAccessibilityContractRemainsStable() throws {
    let source = try ViewSourceScan.source(named: "PlaybackTimelineSection.swift")
    let text = try ViewSourceScan.executableText(of: source)
    let lines = text.components(separatedBy: "\n")
    let overlayRanges = Self.bracedRanges(containing: ".overlay(", in: lines)

    #expect(
      ViewSourceScan.occurrences(of: [".accessibilityIdentifier(PlayerAccessibilityID.expandedScrubber)"], in: text)
        == 1,
      "PlaybackTimelineSection must keep one expandedScrubber identifier so the existing adjustable scrubber remains the dismissal and accessibility surface."
    )
    #expect(
      overlayRanges.allSatisfy { range in
        lines[range].contains { $0.contains(".accessibility") } == false
      },
      "The feedback bubble is visual-only and must not add an accessibility element or alter the scrubber's existing VoiceOver contract."
    )
  }

  /// Driving layout inside the poll is what makes this a barrier rather than a sampler: SwiftUI
  /// commits nothing unless something asks it to lay out, so a barrier that only reads the probe
  /// would settle on a frame the run never actually recomputed.
  @MainActor
  private static func settledScrubberFrame(
    in window: UIWindow,
    hostingController: UIHostingController<HostedPlayerChrome>
  ) async throws -> CGRect {
    await awaitQuiescence("the scrubber frame") {
      window.layoutIfNeeded()
      hostingController.view.layoutIfNeeded()
      return PlayerLayoutProbe.frame(.scrubber).map { "\($0)" } ?? "unmeasured"
    }
    return try #require(
      PlayerLayoutProbe.frame(.scrubber), "the probe never reported a scrubber frame")
  }

  private static func bracedRanges(containing marker: String, in lines: [String]) -> [ClosedRange<Int>] {
    var ranges: [ClosedRange<Int>] = []
    var depth = 0
    for index in lines.indices {
      let line = lines[index]
      let before = depth
      depth += line.reduce(into: 0) { count, character in
        if character == "{" { count += 1 }
        if character == "}" { count -= 1 }
      }
      guard line.contains(marker), line.contains("{") else { continue }
      var end = index
      var nestedDepth = depth
      while end + 1 < lines.count && nestedDepth > before {
        end += 1
        nestedDepth += lines[end].reduce(into: 0) { count, character in
          if character == "{" { count += 1 }
          if character == "}" { count -= 1 }
        }
      }
      ranges.append(index...end)
    }
    return ranges
  }
}

@MainActor
private struct HostedPlayerChrome: View {
  let playback: PlaybackModel
  let player: any PlaybackControlling
  let playbackRate: PlaybackRateCoordinator
  let seekFeedback: SeekFeedbackState

  @State private var isShowingSleepTimer = false
  @State private var isShowingUpNext = false

  var body: some View {
    PlayerChromeRegion(
      player: player,
      playback: playback,
      itemID: "seek-layout-item",
      episodeID: nil,
      fallbackChapterMap: nil,
      fallbackTotalDuration: 3_600,
      isEnabled: true,
      timelineReadoutStyle: CoverAmbientPalette.fallbackCanvas(for: .dark).timelineReadoutStyle,
      seekFeedback: seekFeedback,
      playPauseFill: .blue,
      playbackRate: playbackRate,
      isShowingSleepTimer: $isShowingSleepTimer,
      isShowingUpNext: $isShowingUpNext,
      loadedItemID: nil,
      loadedEpisodeID: nil
    )
    .padding(.horizontal, 24)
    .preferredColorScheme(.dark)
  }
}
