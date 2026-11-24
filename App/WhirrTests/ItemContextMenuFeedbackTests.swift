import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

struct ItemContextMenuFeedbackTests {
  /// `ItemActionsModel.queueFeedbackMessage` is shown on the per-screen channel that
  /// `itemActionErrorAlert` attaches everywhere, so a successful Add to Up Next from a browse row
  /// confirms itself.
  @Test("a populated queue confirmation is shown; nothing is shown without one")
  func queueFeedbackVisibility() {
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(ListeningQueueCopy.playingNext))
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(ListeningQueueCopy.addedToUpNext))
    #expect(
      ItemContextMenuPresentation.QueueFeedback.isVisible(ListeningQueueCopy.alreadyInUpNext))
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(SavedForLaterCopy.saved))
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(SavedForLaterCopy.alreadySaved))
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(SavedForLaterCopy.removed))
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(nil) == false)
    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible("") == false)
  }

  /// The animation must stay inside the overlay: applying it to the composed view animates the
  /// attached screen's list and makes it drop touches while a row change settles.
  @Test("the banner animates itself, not the screen it is attached to")
  func bannerAnimationIsScopedToOverlay() throws {
    let source = try #require(
      try ViewSourceScan.sources().first { $0.lastPathComponent == "ItemContextMenuFeedback.swift" })
    let text = try ViewSourceScan.executableText(of: source)
    let overlay = try #require(text.range(of: ".overlay(alignment: .bottom)"))
    let animation = try #require(text.range(of: ".animation("))
    let sensoryFeedback = try #require(text.range(of: ".sensoryFeedback(trigger: message)"))
    let hitTesting = try #require(text.range(of: ".allowsHitTesting(false)"))

    #expect(ViewSourceScan.occurrences(of: [".animation("], in: text) == 1)
    #expect(animation.lowerBound > overlay.upperBound)
    #expect(animation.upperBound < sensoryFeedback.lowerBound)
    #expect(hitTesting.lowerBound > overlay.upperBound)
    #expect(hitTesting.upperBound < sensoryFeedback.lowerBound)
  }

  @Test("the queue confirmation is transient, not an alert the listener has to dismiss")
  func queueFeedbackIsTransient() {
    #expect(ItemContextMenuPresentation.QueueFeedback.visibleDuration > 0)
    #expect(ItemContextMenuPresentation.QueueFeedback.visibleDuration <= 5)
  }

  @Test("feedback uses an action-specific symbol instead of a plain text capsule")
  func feedbackSymbolsMatchTheirActions() {
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: ListeningQueueCopy.playingNext)
        == "text.line.first.and.arrowtriangle.forward")
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(
        for: ListeningQueueCopy.addedToUpNext)
        == "text.line.last.and.arrowtriangle.forward")
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: SavedForLaterCopy.saved)
        == "bookmark.fill")
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: ContinueListeningCopy.removed)
        == "eye.slash")
  }

  @Test("a confirmed mutation taps; an already-there confirmation taps more softly")
  func feedbackHapticsDistinguishMutationFromNoOp() {
    let mutation = SensoryFeedback.impact(weight: .light, intensity: 0.7)
    let noOp = SensoryFeedback.impact(flexibility: .soft, intensity: 0.4)

    for message in [
      ListeningQueueCopy.playingNext,
      ListeningQueueCopy.addedToUpNext,
      SavedForLaterCopy.saved,
      SavedForLaterCopy.removed,
      ContinueListeningCopy.removed,
    ] {
      #expect(ItemContextMenuPresentation.QueueFeedback.haptic(for: message) == mutation)
    }

    for message in [ListeningQueueCopy.alreadyInUpNext, SavedForLaterCopy.alreadySaved] {
      #expect(ItemContextMenuPresentation.QueueFeedback.haptic(for: message) == noOp)
    }
  }

  /// The Send to E-reader confirmation names the device, so the banner matches its prefix rather
  /// than the exact copy.
  @Test("a sent ebook confirms with the paper plane and the ordinary mutation tap")
  func ebookDeliveryConfirmation() {
    let message = EbookDeliveryCopy.sent(deviceName: "Rhys's Kindle")

    #expect(ItemContextMenuPresentation.QueueFeedback.isVisible(message))
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: message)
        == EbookDeliveryCopy.sentSystemImage)
    #expect(
      ItemContextMenuPresentation.QueueFeedback.haptic(for: message) == ItemActionHaptics.mutation)
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: "Sentinel value") == "checkmark")
  }
}

struct PlayNextFeedbackIconTests {
  @Test("both Play Next confirmations take the Play Next glyph")
  func playNextIconMatchesBothForms() {
    let playNext = "text.line.first.and.arrowtriangle.forward"
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: ListeningQueueCopy.playingNext)
        == playNext)
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(
        for: ListeningQueueCopy.playNextConfirmation(afterList: "Commute")) == playNext)
    #expect(
      ItemContextMenuPresentation.QueueFeedback.systemImage(for: ListeningQueueCopy.addedToUpNext)
        != playNext)
  }
}
