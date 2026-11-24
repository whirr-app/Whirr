import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine
import Testing
import UIKit

@testable import Whirr

/// Every upper-content variance must leave the lower chrome at the same screen coordinate.
@MainActor
@Suite("Expanded player chrome layout", .serialized)
struct ExpandedPlayerChromeLayoutTests {

  // MARK: - Chrome anchors across upper-content variants

  @Test("the scrubber minY is invariant across podcast and chaptered audiobook metadata")
  func scrubberMinYDoesNotMove() async throws {
    let pair = try await measureFixturePair()
    let tolerance = 1.0 / pair.displayScale

    #expect(
      abs(pair.podcast.scrubber.minY - pair.audiobook.scrubber.minY) <= tolerance,
      "scrubber minY: A=\(pair.podcast.scrubber.minY) B=\(pair.audiobook.scrubber.minY)"
    )
  }

  @Test("the transport row midY is invariant across podcast and chaptered audiobook metadata")
  func transportMidYDoesNotMove() async throws {
    let pair = try await measureFixturePair()
    let tolerance = 1.0 / pair.displayScale

    #expect(
      abs(pair.podcast.transport.midY - pair.audiobook.transport.midY) <= tolerance,
      "transport midY: A=\(pair.podcast.transport.midY) B=\(pair.audiobook.transport.midY)"
    )
  }

  @Test("the quick-action row bottom is invariant across podcast and chaptered audiobook metadata")
  func quickActionsBottomDoesNotMove() async throws {
    let pair = try await measureFixturePair()
    let tolerance = 1.0 / pair.displayScale

    #expect(
      abs(pair.podcast.quickActions.maxY - pair.audiobook.quickActions.maxY) <= tolerance,
      "quick-actions bottom: A=\(pair.podcast.quickActions.maxY) B=\(pair.audiobook.quickActions.maxY)"
    )
  }

  /// Guards the other three from passing vacuously: if the two fixtures ever stop differing above
  /// the timeline, the invariant they assert would be trivially true.
  @Test("the two fixtures really do differ in the metadata above the timeline")
  func fixturesDifferAboveTheTimeline() async throws {
    let pair = try await measureFixturePair()
    let tolerance = 1.0 / pair.displayScale

    #expect(
      abs(pair.podcast.metadata.height - pair.audiobook.metadata.height) > tolerance,
      "metadata height: A=\(pair.podcast.metadata.height) B=\(pair.audiobook.metadata.height)"
    )
  }

  @Test("one-, two-, and three-line static titles do not move the chrome")
  func staticTitleLineVariantsKeepChromeAnchored() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.oneLineTitle, .twoLineTitle, .threeLineTitle])
    let tolerance = 1.0 / measurement.displayScale
    let frames = measurement.frames

    expectChromeInvariant(frames[0], frames[1], tolerance: tolerance, label: "one vs two lines")
    expectChromeInvariant(frames[0], frames[2], tolerance: tolerance, label: "one vs three lines")
    expectChromeInvariant(frames[1], frames[2], tolerance: tolerance, label: "two vs three lines")
    #expect(
      frames[1].metadata.height > frames[0].metadata.height + tolerance,
      "two-line metadata did not grow: one=\(frames[0].metadata.height) two=\(frames[1].metadata.height)"
    )
    #expect(
      frames[2].metadata.height > frames[1].metadata.height + tolerance,
      "three-line metadata did not grow: two=\(frames[1].metadata.height) three=\(frames[2].metadata.height)"
    )
  }

  @Test("a title past the three-line budget truncates at three lines and does not move the chrome")
  func overBudgetTitleTruncatesAtTheBudget() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.threeLineTitle, .overBudgetTitle])
    let tolerance = 1.0 / measurement.displayScale
    let threeLine = measurement.frames[0]
    let overBudget = measurement.frames[1]

    expectChromeInvariant(
      threeLine, overBudget, tolerance: tolerance, label: "three lines vs over budget")
    #expect(
      abs(overBudget.metadata.height - threeLine.metadata.height) <= tolerance,
      "over-budget title did not hold the three-line band: three=\(threeLine.metadata.height) over=\(overBudget.metadata.height)"
    )
  }

  @Test("a confirmed-chapterless book and a chaptered book keep the chrome anchored")
  func chapterlessAndChapteredBooksKeepChromeAnchored() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.chapterlessBook, .audiobook])
    let tolerance = 1.0 / measurement.displayScale
    let chapterless = measurement.frames[0]
    let chaptered = measurement.frames[1]

    expectChromeInvariant(chapterless, chaptered, tolerance: tolerance, label: "chapterless vs chaptered")
    #expect(
      abs(chapterless.metadata.height - chaptered.metadata.height) > tolerance,
      "chapter row did not change the upper metadata band: chapterless=\(chapterless.metadata.height) chaptered=\(chaptered.metadata.height)"
    )
  }

  @Test("unresolved chapter metadata resolving on the same host keeps the chrome anchored")
  func unresolvedThenResolvedChaptersKeepChromeAnchored() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.unresolvedBook, .resolvedBook])
    let tolerance = 1.0 / measurement.displayScale

    expectChromeInvariant(
      measurement.frames[0], measurement.frames[1], tolerance: tolerance,
      label: "unresolved vs resolved chapters")
  }

  @Test("hidden and visible status banners do not move the chrome")
  func statusBannerVisibilityKeepsChromeAnchored() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.statusHidden, .statusVisible],
      playbackState: .recoverableError,
      beforeFixture: { index, dependencies in
        guard index == 1 else { return }
        await dependencies.playback.start(
          itemID: Fixture.statusHidden.itemID,
          episodeID: Fixture.statusHidden.episodeID,
          origin: .queueAdvance)
        #expect(dependencies.playback.phase == .recoverableError)
        #expect(dependencies.playback.startFailureMessage != nil)
      })
    let tolerance = 1.0 / measurement.displayScale
    let hidden = measurement.frames[0]
    let visible = measurement.frames[1]

    expectChromeInvariant(hidden, visible, tolerance: tolerance, label: "banner hidden vs visible")
    #expect(
      abs(hidden.metadata.minY - visible.metadata.minY) > tolerance
        || abs(hidden.metadata.height - visible.metadata.height) > tolerance,
      "status banner did not change the upper region: hidden=\(hidden.metadata) visible=\(visible.metadata)"
    )
  }

  @Test("375x812 and 402x874 each keep the chrome invariant within the container")
  func compactContainerSizesKeepChromeAnchoredIndependently() async throws {
    let sizes = [
      CGRect(x: 0, y: 0, width: 375, height: 812),
      CGRect(x: 0, y: 0, width: 402, height: 874),
    ]

    for bounds in sizes {
      let pair = try await measureFixturePair(windowBounds: bounds)
      let tolerance = 1.0 / pair.displayScale
      let label = "\(Int(bounds.width))x\(Int(bounds.height))"

      expectChromeInvariant(
        pair.podcast, pair.audiobook, tolerance: tolerance, label: "container \(label)")
      expectUpperRegionChanged(
        pair.podcast, pair.audiobook, tolerance: tolerance, label: "container \(label)")
      expectChromeInside(
        pair.podcast, bounds: bounds, tolerance: tolerance, label: "podcast \(label)")
      expectChromeInside(
        pair.audiobook, bounds: bounds, tolerance: tolerance, label: "audiobook \(label)")
    }
  }

  // MARK: - Measure and hold the upper artwork layout

  /// Instrument only. Its printed table is the result. Keep this test red only when the probe
  /// failed to publish a measurement.
  @Test("record measured expanded-player layout coordinates")
  func recordMeasuredLayoutCoordinates() async throws {
    let containers = [
      CGRect(x: 0, y: 0, width: 375, height: 812),
      CGRect(x: 0, y: 0, width: 393, height: 852),
      CGRect(x: 0, y: 0, width: 402, height: 874),
      CGRect(x: 0, y: 0, width: 375, height: 667),
    ]

    print(
      "| Container | Fixture | safe top | safe left | safe bottom | safe right "
        + "| upper region | metadata band | cover height | cover minY | slack above cover |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

    for bounds in containers {
      let pair = try await measureFixturePair(
        windowBounds: bounds, dynamicTypeSize: .large,
        targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
      let regionOrigin = bounds.minY + pair.safeAreaInsets.top + Self.dismissHandleHeight

      for (name, frames) in [("podcast", pair.podcast), ("audiobook", pair.audiobook)] {
        // The probe stores global-space frames. The page's safe-content origin is the window's
        // origin plus the resolved top inset, and dismissHandle reserves a fixed 28pt container;
        // subtracting those two pieces from chrome.minY leaves the flexible upper region itself.
        let upperRegionHeight = frames.chrome.minY - regionOrigin
        let slackAboveCover = frames.cover.minY - regionOrigin
        let values = [
          pair.safeAreaInsets.top, pair.safeAreaInsets.left, pair.safeAreaInsets.bottom,
          pair.safeAreaInsets.right, upperRegionHeight, frames.metadata.height,
          frames.cover.height, frames.cover.minY, slackAboveCover,
        ]
        #expect(
          values.allSatisfy { $0.isFinite },
          "\(Int(bounds.width))x\(Int(bounds.height)) \(name) did not publish finite layout measurements"
        )

        print(
          "| \(Int(bounds.width))×\(Int(bounds.height)) | \(name) | \(pair.safeAreaInsets.top) | \(pair.safeAreaInsets.left) | \(pair.safeAreaInsets.bottom) | \(pair.safeAreaInsets.right) | \(upperRegionHeight) | \(frames.metadata.height) | \(frames.cover.height) | \(frames.cover.minY) | \(slackAboveCover) |"
        )
      }
    }
  }

  /// The metadata probe is the live band for these title-only fixtures. The two deltas are the
  /// actual `.title2.weight(.bold)` line height at large Dynamic Type, not an assumed ~27pt.
  @Test("record live large Dynamic Type metadata line heights")
  func recordLargeDynamicTypeMetadataLineHeights() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.oneLineTitle, .twoLineTitle, .threeLineTitle],
      windowBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
      dynamicTypeSize: .large,
      targetSafeAreaInsets: Self.targetSafeAreaInsets(for: CGRect(x: 0, y: 0, width: 393, height: 852)))
    #expect(measurement.frames.count == 3, "expected one-, two-, and three-line measurements")
    guard measurement.frames.count == 3 else { return }

    let oneLine = measurement.frames[0].metadata.height
    let twoLine = measurement.frames[1].metadata.height
    let threeLine = measurement.frames[2].metadata.height
    let oneToTwoDelta = twoLine - oneLine
    let twoToThreeDelta = threeLine - twoLine
    #expect(
      [oneLine, twoLine, threeLine, oneToTwoDelta, twoToThreeDelta].allSatisfy { $0.isFinite },
      "metadata measurements were not finite")

    print("| Title fixture | metadata band height |")
    print("|---|---:|")
    print("| one line | \(oneLine) |")
    print("| two lines | \(twoLine) |")
    print("| three lines | \(threeLine) |")
    print("one-to-two line delta: \(oneToTwoDelta)")
    print("two-to-three line delta: \(twoToThreeDelta)")
  }

  @Test("the worst nominal band is chaptered and remains three wrapped title lines")
  func worstNominalBandUsesThreeWrappedTitleLines() async throws {
    let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    let measurement = try await measureFixtureSequence(
      fixtures: [.threeLineTitle, .threeLineChapteredTitle],
      windowBounds: bounds,
      dynamicTypeSize: .large,
      targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
    #expect(measurement.frames.count == 2, "expected static and chaptered three-line measurements")
    guard measurement.frames.count == 2 else { return }

    let tolerance = 1.0 / measurement.displayScale
    let staticBand = measurement.frames[0].metadata.height
    let chapteredBand = measurement.frames[1].metadata.height
    let chapterRowContribution = WhirrSpacing.xSmall + PlayerMetric.chapterRowMinHeight
    #expect(
      abs(staticBand - 105.33) <= tolerance,
      "static three-line title did not measure three wrapped lines: band=\(staticBand)")
    #expect(
      abs((chapteredBand - staticBand) - chapterRowContribution) <= tolerance,
      "chapter row contribution changed: static=\(staticBand) chaptered=\(chapteredBand)")
    #expect(
      abs(chapteredBand - 157.33) <= tolerance,
      "worst nominal chaptered band was not 157.33pt: band=\(chapteredBand)")
  }

  /// Quantifies the banner exemption: how much a drawn status banner adds to the measured band.
  ///
  /// The metadata probe covers `ListeningMetadataSection` only; the banner is its sibling in the
  /// measured band, so its height is derived from the cover, and the bound's direction depends
  /// on which clamp resolved the cover:
  ///
  /// - share or width cap: `region - large - cover` is a loose upper bound on the band;
  /// - `minimumCoverSize`: the band term was pushed below the floor, so it is a lower bound;
  /// - the band term itself: exact.
  ///
  /// The recoverable-error case lands on the floor, so this records a lower bound, the useful
  /// direction: the banner is unbounded (no `lineLimit`), so no gated screen can be asked to fit.
  @Test("record recoverable-error status banner band height")
  func recordRecoverableErrorStatusBannerBandHeight() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.statusHidden, .statusVisible],
      windowBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
      dynamicTypeSize: .large,
      targetSafeAreaInsets: Self.targetSafeAreaInsets(for: CGRect(x: 0, y: 0, width: 393, height: 852)),
      playbackState: .recoverableError,
      beforeFixture: { index, dependencies in
        guard index == 1 else { return }
        await dependencies.playback.start(
          itemID: Fixture.statusHidden.itemID,
          episodeID: Fixture.statusHidden.episodeID,
          origin: .queueAdvance)
        #expect(dependencies.playback.phase == .recoverableError)
        #expect(dependencies.playback.startFailureMessage != nil)
      })
    #expect(measurement.frames.count == 2, "expected hidden and visible banner measurements")
    guard measurement.frames.count == 2 else { return }

    let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    let regionOrigin = bounds.minY + measurement.safeAreaInsets.top + Self.dismissHandleHeight
    let hidden = measurement.frames[0]
    let visible = measurement.frames[1]
    let hiddenRegionHeight = hidden.chrome.minY - regionOrigin
    let visibleRegionHeight = visible.chrome.minY - regionOrigin
    let hiddenBand = hiddenRegionHeight - WhirrSpacing.large - hidden.cover.height
    let visibleBand = visibleRegionHeight - WhirrSpacing.large - visible.cover.height
    let hiddenBanner = hiddenBand - hidden.metadata.height
    let visibleBanner = visibleBand - visible.metadata.height
    #expect(
      [
        hidden.cover.height, visible.cover.height, hiddenRegionHeight, visibleRegionHeight,
        hiddenBand, visibleBand, hiddenBanner, visibleBanner,
      ].allSatisfy { $0.isFinite },
      "status banner measurements were not finite")

    print(
      "| Status fixture | cover | region | band bound | direction | metadata | banner bound |")
    print("|---|---:|---:|---:|---|---:|---:|")
    for (name, frames, regionHeight, band, banner) in [
      ("hidden", hidden, hiddenRegionHeight, hiddenBand, hiddenBanner),
      ("visible", visible, visibleRegionHeight, visibleBand, visibleBanner),
    ] {
      print(
        "| \(name) | \(frames.cover.height) | \(regionHeight) | \(band) "
          + "| \(Self.bandBoundDirection(cover: frames.cover.height, regionHeight: regionHeight)) "
          + "| \(frames.metadata.height) | \(banner) |")
    }
  }

  /// Reproduction of the defect. This is red today: the same cover sits about 52pt lower for the
  /// podcast because all spare height is above it. After the fix the fixtures still differ: each
  /// takes 0.3 of its own slack, about 17pt for the podcast and 1.4pt for the chaptered audiobook,
  /// leaving about 15.6pt. The 20pt tolerance covers that real difference. It is not a rounding
  /// tolerance.
  @Test("podcast and audiobook cover top edges agree within the design bound")
  func coverTopEdgesAgreeAcrossFixtures() async throws {
    let containers = [
      CGRect(x: 0, y: 0, width: 375, height: 812),
      CGRect(x: 0, y: 0, width: 393, height: 852),
      CGRect(x: 0, y: 0, width: 402, height: 874),
    ]

    for bounds in containers {
      let pair = try await measureFixturePair(
        windowBounds: bounds, dynamicTypeSize: .large,
        targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
      let label = "\(Int(bounds.width))x\(Int(bounds.height))"
      #expect(
        abs(pair.podcast.cover.minY - pair.audiobook.cover.minY)
          <= Self.coverTopEdgeTolerance,
        "\(label) cover minY: podcast=\(pair.podcast.cover.minY) audiobook=\(pair.audiobook.cover.minY)"
      )
    }
  }

  /// Regression guard, not a reproduction: both fixtures resolve to the same cover height today.
  /// They need not. A podcast can sit on the width cap while an audiobook, whose metadata band is
  /// taller, falls to the band term, so removing the height-relative cap would make this go red.
  /// The 3pt bound is set for 375x812, where the two clamps cross and the fixtures land about 1.8pt
  /// apart: one on the share cap, one on the band term.
  @Test("podcast and audiobook cover heights agree within the guard bound")
  func coversAgreeAcrossFixtures() async throws {
    let containers = [
      CGRect(x: 0, y: 0, width: 375, height: 812),
      CGRect(x: 0, y: 0, width: 393, height: 852),
      CGRect(x: 0, y: 0, width: 402, height: 874),
    ]

    for bounds in containers {
      let pair = try await measureFixturePair(
        windowBounds: bounds, dynamicTypeSize: .large,
        targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
      let label = "\(Int(bounds.width))x\(Int(bounds.height))"
      #expect(
        abs(pair.podcast.cover.height - pair.audiobook.cover.height)
          <= Self.coverAgreementTolerance,
        "\(label) cover height: podcast=\(pair.podcast.cover.height) audiobook=\(pair.audiobook.cover.height)"
      )
    }
  }

  /// Record-only companion to the upper-artwork measurement. This capture follows
  /// `scope.window.layoutIfNeeded()`, by which point SwiftUI has already run the geometry feedback
  /// and republished. It shows what this host can actually display: the settled cover position is
  /// reached within one layout pass, and the seed produces no observable jump. Keep it out of
  /// `settledChromeFrames`.
  @Test("record first-frame cover position drift")
  func recordFirstFrameCoverPositionDrift() async throws {
    let measurement = try await measureFixtureSequence(
      fixtures: [.podcast, .audiobook],
      windowBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
      dynamicTypeSize: .large,
      targetSafeAreaInsets: Self.targetSafeAreaInsets(for: CGRect(x: 0, y: 0, width: 393, height: 852)),
      captureFirstCoverFrames: true)
    #expect(measurement.frames.count == 2, "expected settled podcast and audiobook frames")
    #expect(measurement.firstCoverFrames.count == 2, "expected two first-frame cover captures")
    guard measurement.frames.count == 2, measurement.firstCoverFrames.count == 2 else { return }

    for (index, name) in ["podcast", "audiobook"].enumerated() {
      let first = measurement.firstCoverFrames[index]?.minY
      let settled = measurement.frames[index].cover.minY
      let drift = first.map { $0 - settled }
      print(
        "\(name) first-frame cover minY=\(String(describing: first)) settled minY=\(settled) drift=\(String(describing: drift))"
      )
    }
  }

  // MARK: - Budget the chrome is allowed to spend

  /// Guards against a chrome that eats the whole page. The invariant tests above are all satisfied
  /// by one, so the artwork, which they exist to protect, needs its own floor with a margin. A bare
  /// inequality would pass at 211.
  @Test("device insets still leave the artwork clear of its floor at ordinary Dynamic Type")
  func coverStaysClearOfItsFloorUnderDeviceInsets() async throws {
    for bounds in Self.compactContainers {
      let pair = try await measureFixturePair(
        windowBounds: bounds, targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
      let label = "\(Int(bounds.width))x\(Int(bounds.height))"
      #expect(
        pair.safeAreaInsets.bottom >= 34,
        "\(label) did not receive a home-indicator-sized bottom inset: \(pair.safeAreaInsets)")

      for (name, frames) in [("podcast", pair.podcast), ("audiobook", pair.audiobook)] {
        let floor = ExpandedPlayerView.minimumCoverSize
        let message =
          "\(label) \(name) cover \(frames.cover.height) is within \(Self.coverFloorMargin)pt of the \(floor)pt floor"
        #expect(frames.cover.height >= floor + Self.coverFloorMargin, Comment(rawValue: message))
      }
    }
  }

  /// The clearance is measured from the container's physical bottom edge. That is the point of the
  /// change: the distance does not depend on what inset the device reports.
  @Test("the chrome sits one named clearance above the physical bottom edge")
  func chromeSitsAtItsNamedBottomClearance() async throws {
    for insets in [UIEdgeInsets.zero, Self.targetSafeAreaInsets(for: Self.windowBounds)] {
      let pair = try await measureFixturePair(targetSafeAreaInsets: insets)
      let tolerance = 1.0 / pair.displayScale

      for (name, frames) in [("podcast", pair.podcast), ("audiobook", pair.audiobook)] {
        let clearance = Self.windowBounds.maxY - frames.chrome.maxY
        let message =
          "\(name) chrome bottom \(frames.chrome.maxY) sits \(clearance)pt above \(Self.windowBounds.maxY), not \(PlayerMetric.chromeBottomClearance)pt (insets \(pair.safeAreaInsets))"
        #expect(
          abs(clearance - PlayerMetric.chromeBottomClearance) <= tolerance,
          Comment(rawValue: message))
      }
    }
  }

  /// At accessibility sizes the chrome is much taller, and crowding against the home indicator is
  /// real. The page therefore stops spending the inset and sits inside it.
  @Test("accessibility Dynamic Type hands the whole bottom inset back")
  func accessibilitySizesRespectTheWholeBottomInset() async throws {
    let pair = try await measureFixturePair(
      dynamicTypeSize: .accessibility3,
      targetSafeAreaInsets: Self.targetSafeAreaInsets(for: Self.windowBounds))
    let tolerance = 1.0 / pair.displayScale
    let expected =
      Self.windowBounds.maxY - pair.safeAreaInsets.bottom - PlayerMetric.chromeBottomClearance

    #expect(
      pair.safeAreaInsets.bottom > PlayerMetric.chromeBottomClearance,
      "the fallback is untested unless the inset exceeds the clearance: \(pair.safeAreaInsets)")
    #expect(
      abs(pair.podcast.chrome.maxY - expected) <= tolerance,
      "accessibility chrome bottom \(pair.podcast.chrome.maxY) != \(expected)")
  }

  /// Standing guard. Every point of the chrome's height is a token or a leaf, so a system view that
  /// reports no intrinsic content size, such as `AVRoutePickerView`, inflates the region and fails
  /// here, on a number, rather than on a device later as "the artwork looks small".
  @Test("the chrome's height is exactly the sum of its named parts")
  func chromeHeightIsTheSumOfItsNamedParts() async throws {
    for size in [DynamicTypeSize.large, .accessibility3] {
      let pair = try await measureFixturePair(
        dynamicTypeSize: size,
        targetSafeAreaInsets: Self.targetSafeAreaInsets(for: Self.windowBounds))
      let tolerance = 1.0 / pair.displayScale

      for (name, frames) in [("podcast", pair.podcast), ("audiobook", pair.audiobook)] {
        let sum =
          PlayerMetric.chromeTopSeam
          + frames.scrubber.height
          + PlayerMetric.chromeScrubberToTransportSpacing
          + frames.transport.height
          + PlayerMetric.chromeTransportToQuickActionsSpacing
          + frames.quickActions.height
        let message =
          "\(size) \(name) chrome \(frames.chrome.height) != summed \(sum) (scrubber \(frames.scrubber.height), transport \(frames.transport.height), quick actions \(frames.quickActions.height))"
        #expect(abs(frames.chrome.height - sum) <= tolerance, Comment(rawValue: message))
      }

      // The quick-action row swallowed the page's slack. Pinning it to its own token makes the sum
      // above a real constraint rather than an identity.
      let quickActionValues = PlayerQuickActionLayoutValues.resolve(
        isAccessibilitySize: size.isAccessibilitySize)
      let expectedQuickActions = quickActionValues.minimumHeight
      #expect(
        abs(pair.podcast.quickActions.height - expectedQuickActions) <= tolerance,
        "\(size) quick actions \(pair.podcast.quickActions.height) != \(expectedQuickActions)")
    }
  }

  // MARK: - Dynamic Type and overflow keep upper content off the chrome

  @Test("ordinary and accessibility Dynamic Type keep upper variants off the chrome")
  func dynamicTypeSizesKeepChromeAnchored() async throws {
    let ordinary = try await measureFixtureSequence(
      fixtures: [.oneLineTitle, .overBudgetTitle], dynamicTypeSize: .large)
    let accessibility = try await measureFixtureSequence(
      fixtures: [.oneLineTitle, .overBudgetTitle], dynamicTypeSize: .accessibility3)
    let ordinaryTolerance = 1.0 / ordinary.displayScale
    let accessibilityTolerance = 1.0 / accessibility.displayScale

    expectChromeInvariant(
      ordinary.frames[0], ordinary.frames[1], tolerance: ordinaryTolerance,
      label: "ordinary Dynamic Type")
    expectChromeInvariant(
      accessibility.frames[0], accessibility.frames[1], tolerance: accessibilityTolerance,
      label: "accessibility Dynamic Type")
    expectChromeInside(
      ordinary.frames[0], bounds: Self.windowBounds, tolerance: ordinaryTolerance,
      label: "ordinary one-line")
    expectChromeInside(
      ordinary.frames[1], bounds: Self.windowBounds, tolerance: ordinaryTolerance,
      label: "ordinary over budget")
    expectChromeInside(
      accessibility.frames[0], bounds: Self.windowBounds, tolerance: accessibilityTolerance,
      label: "accessibility one-line")
    expectChromeInside(
      accessibility.frames[1], bounds: Self.windowBounds, tolerance: accessibilityTolerance,
      label: "accessibility over budget")
    #expect(
      accessibility.frames[1].metadata.height > ordinary.frames[1].metadata.height + ordinaryTolerance,
      "accessibility title did not grow intrinsically: ordinary=\(ordinary.frames[1].metadata.height) accessibility=\(accessibility.frames[1].metadata.height)"
    )
  }

  @Test("overflowing accessibility upper content scrolls without pushing the chrome")
  func overflowingUpperContentDoesNotPushChrome() async throws {
    let bounds = CGRect(x: 0, y: 0, width: 375, height: 812)
    let measurement = try await measureFixtureSequence(
      fixtures: [.overflowBaseline, .overflowContent],
      windowBounds: bounds,
      dynamicTypeSize: .accessibility3,
      playbackState: .recoverableError,
      beforeHosting: { dependencies in
        await dependencies.playback.start(
          itemID: Fixture.overflowBaseline.itemID,
          episodeID: Fixture.overflowBaseline.episodeID,
          origin: .queueAdvance)
        #expect(dependencies.playback.phase == .recoverableError)
        #expect(dependencies.playback.startFailureMessage != nil)
      })
    let tolerance = 1.0 / measurement.displayScale
    let baseline = measurement.frames[0]
    let overflowing = measurement.frames[1]

    expectChromeInvariant(
      baseline, overflowing, tolerance: tolerance,
      label: "non-overflowing vs overflowing accessibility content")
    expectChromeInside(
      baseline, bounds: bounds, tolerance: tolerance, label: "non-overflowing accessibility content")
    expectChromeInside(
      overflowing, bounds: bounds, tolerance: tolerance, label: "overflowing accessibility content")
    #expect(
      overflowing.metadata.height > baseline.metadata.height + tolerance,
      "overflow fixture did not materially grow the upper metadata: baseline=\(baseline.metadata.height) overflowing=\(overflowing.metadata.height)"
    )
  }

  // MARK: - Ordinary Dynamic Type fits without scrolling

  @Test("the column does not scroll at ordinary Dynamic Type")
  func theColumnDoesNotScrollAtOrdinaryDynamicType() async throws {
    let exemptContainer = CGRect(x: 0, y: 0, width: 375, height: 667)
    let allContainers = [exemptContainer] + Self.gatedContainers
    let expectedWorstNominalBand: CGFloat = 157.33
    let ordinaryNoScrollMargin: CGFloat = 20

    for bounds in allContainers {
      let targetInsets = Self.targetSafeAreaInsets(for: bounds)
      var scrollObservation: (count: Int, contentHeight: CGFloat, boundsHeight: CGFloat)?
      let measurement = try await measureFixtureSequence(
        fixtures: [.threeLineChapteredTitle],
        windowBounds: bounds,
        dynamicTypeSize: .large,
        targetSafeAreaInsets: targetInsets,
        afterFixture: { window, hostingController, frames in
          // Duplicated from `ExpandedPlayerDismissalBoundaryHost` because its walk is file-private.
          // Sharing it would change that helper's ownership and scope.
          let scrollViews = Self.scrollViewsInBreadthFirstOrder(from: hostingController.view)
          let tolerance = 1.0 / max(window.screen.scale, 1)
          #expect(
            scrollViews.count == 1,
            "\(Int(bounds.width))x\(Int(bounds.height)) hosted player exposed \(scrollViews.count) scroll views")
          guard let scrollView = scrollViews.first else { return }

          scrollObservation = (
            count: scrollViews.count,
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height
          )
          if bounds != exemptContainer {
            #expect(
              scrollView.contentSize.height <= scrollView.bounds.height + tolerance,
              "\(Int(bounds.width))x\(Int(bounds.height)) nominal content overflowed: content=\(scrollView.contentSize.height) bounds=\(scrollView.bounds.height)"
            )
          }
          #expect(
            frames.metadata.height >= expectedWorstNominalBand - tolerance,
            "\(Int(bounds.width))x\(Int(bounds.height)) fixture did not retain the worst nominal band: band=\(frames.metadata.height)"
          )
        })
      #expect(measurement.frames.count == 1, "expected one worst-nominal-band measurement")
      guard let frames = measurement.frames.first else { continue }

      let tolerance = 1.0 / measurement.displayScale
      let regionOrigin = bounds.minY + measurement.safeAreaInsets.top + Self.dismissHandleHeight
      let regionHeight = frames.chrome.minY - regionOrigin
      let band = frames.metadata.height
      let margin = regionHeight - WhirrSpacing.large - band - ExpandedPlayerView.minimumCoverSize
      let observation = scrollObservation
      print(
        "ordinary no-scroll \(Int(bounds.width))×\(Int(bounds.height)): content=\(String(describing: observation?.contentHeight)) bounds=\(String(describing: observation?.boundsHeight)) region=\(regionHeight) band=\(band) margin=\(margin)"
      )

      if bounds != exemptContainer {
        let availableCoverHeight = regionHeight - WhirrSpacing.large - band
        #expect(
          availableCoverHeight
            >= ExpandedPlayerView.minimumCoverSize + ordinaryNoScrollMargin - tolerance,
          "\(Int(bounds.width))x\(Int(bounds.height)) pure layout margin was too small: \(margin)pt")
      }
    }
  }

  // MARK: - No slack is stranded below the metadata

  /// Reproduction of the stranded-slack defect. The upper region top-aligns its column and keeps
  /// only a capped share of its slack above the cover, so the remaining points sat below the
  /// metadata, in a void no token named and nothing drew. The chrome's frame starts at
  /// `chromeTopSeam`, so a flush page leaves zero here, and the seam is the only declared
  /// gap between the band and the scrubber.
  @Test("no slack is stranded between the metadata band and the chrome")
  func theMetadataSitsFlushAgainstTheChrome() async throws {
    for bounds in Self.gatedContainers {
      let pair = try await measureFixturePair(
        windowBounds: bounds,
        targetSafeAreaInsets: Self.targetSafeAreaInsets(for: bounds))
      let tolerance = 1.0 / pair.displayScale
      let label = "\(Int(bounds.width))x\(Int(bounds.height))"

      for (name, frames) in [("podcast", pair.podcast), ("audiobook", pair.audiobook)] {
        let stranded = frames.chrome.minY - frames.metadata.maxY
        #expect(
          stranded <= tolerance,
          Comment(
            rawValue:
              "\(label) \(name) stranded \(stranded)pt below the band: band bottom \(frames.metadata.maxY), chrome top \(frames.chrome.minY)"
          ))
      }
    }
  }
}
