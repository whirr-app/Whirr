import AppModel
import SwiftUI
import Testing

@testable import Whirr

@Suite("Setup flow keyboard layout")
struct SetupFlowLayoutTests {

  @Test("the brand stays fixed while only the form scrolls for keyboard focus")
  func brandIsOutsideScrollableContent() {
    #expect(SetupFlowLayout.fixedRegions == [.brandHeader])
    #expect(SetupFlowLayout.scrollableRegions == [.form])
  }

  @Test("credentials use a compact form without a scroll-clipped outer card")
  func credentialsAvoidOuterCardClipping() {
    #expect(SetupFlowLayout.credentialPresentation == .compactForm)
    #expect(SetupFlowLayout.headerValueFieldPresentation == .secure)
  }

  @MainActor
  @Test("a fresh setup draft defaults to HTTPS")
  func freshSetupDraftDefaultsToHTTPS() {
    #expect(SetupDraft().scheme == .https)
  }

  @MainActor
  @Test("server-scoped setup secrets can be forgotten")
  func serverScopedSetupSecretsAreCleared() {
    let draft = SetupDraft()
    draft.headers = [SetupHeaderDraft(name: "X-Proxy-Token", value: "canary-secret")]

    draft.forgetServerScopedSecrets()

    #expect(draft.headers.isEmpty)
  }

  @Test("setup content uses an adaptive grouped form surface")
  func contentUsesGroupedFormSurface() {
    #expect(SetupFlowLayout.contentPresentation == .groupedForm)
  }

  /// Header rows are `Form` content, not `List` rows. A `swipeActions` modifier on each collapses
  /// onto the one enclosing row, so deletion is a visible per-row button instead. There is one.
  @Test("proxy-header deletion is a visible per-row control, not a swipe")
  func proxyHeaderDeletionIsAVisibleControl() throws {
    let source = try ViewSourceScan.executableText(ofFileNamed: "SetupFlowSharedFields.swift")
    let action = SetupFlowLayout.deleteHeaderAction

    #expect(action.title == "Delete")
    #expect(action.systemImage == "trash")
    #expect(action.role == .destructive)
    #expect(source.contains(".swipeActions") == false)
    #expect(
      ViewSourceScan.occurrences(of: ["Button(role: deleteAction.buttonRole, action: onDelete)"], in: source) == 1)
    #expect(
      ViewSourceScan.occurrences(of: ["removeHeader(withID: header.id"], in: source) == 1)
  }

  /// Opening `Advanced` seeds a header row, because an empty disclosure would need a second tap
  /// before a field exists. The untouched seed must not fail submission as an empty header.
  @MainActor
  @Test("an untouched seeded header row is not submitted and does not fail validation")
  func blankSeededHeaderRowIsIgnored() {
    #expect(SetupHeaderDraft().isBlank)
    #expect(SetupHeaderDraft(name: " ", value: " ").isBlank)
    #expect(SetupHeaderDraft(name: "X-Proxy-Token", value: "").isBlank == false)
    #expect(SetupHeaderDraft(name: "", value: "secret").isBlank == false)
  }

  @Test(
    "focused fields choose an anchor that keeps the active control above the keyboard",
    arguments: [
      (SetupFlowField.server, UnitPoint.center),
      (SetupFlowField.username, UnitPoint.center),
      (SetupFlowField.password, UnitPoint(x: 0.5, y: 0.72)),
    ]
  )
  func focusedFieldScrollAnchor(field: SetupFlowField, expectedAnchor: UnitPoint) {
    #expect(SetupFlowLayout.scrollAnchor(for: field) == expectedAnchor)
  }

  @Test("setup uses one optional focus-scroll animation and disables it under Reduce Motion")
  func setupFocusScrollMotionRespectsReduceMotion() {
    #expect(SetupFlowMotion.focusScrollAnimation(reduceMotion: true) == nil)
    #expect(
      SetupFlowMotion.focusScrollAnimation(reduceMotion: false)
        == .smooth(duration: 0.3))
  }

  /// The discovery-failure screen must not sign out on a tap without confirmation. Alert
  /// presentation has no host-testable seam, so the guard is source-level: the first attempt stays
  /// behind the destructive confirmation, and after a reported failure the only second route is the
  /// canonical retry action.
  @Test("setup signs out only from the confirmation and canonical failure retry")
  func signOutIsOnlyReachableFromTheConfirmationAndRetry() throws {
    let source = try ViewSourceScan.executableText(ofFileNamed: "SetupFlowView.swift")

    let invocations = source.ranges(of: "model.signOut()")
    #expect(invocations.count == 1, "the shared attempt invokes signOut() \(invocations.count) times")

    let attempts = source.ranges(of: "Task { await attemptSignOut() }")
    #expect(attempts.count == 2, "expected confirmation and retry to share one attempt path")

    let confirmationAlert = try #require(source.range(of: ".alert(SettingsCopy.logoutTitle"))
    let confirmation = try #require(
      source.range(of: "Button(SettingsCopy.confirmLogout, role: .destructive)"),
      "no destructive confirmation action")
    let failureAlert = try #require(source.range(of: ".alert(SettingsCopy.logoutFailedTitle"))
    let retry = try #require(source.range(of: "Button(SettingsCopy.retryLogout)"))
    let firstAttempt = try #require(attempts.first)
    let retryAttempt = try #require(attempts.last)
    let invocation = try #require(invocations.first)
    #expect(
      confirmationAlert.lowerBound < confirmation.lowerBound
        && confirmation.lowerBound < firstAttempt.lowerBound
        && firstAttempt.lowerBound < failureAlert.lowerBound,
      "the first sign-out attempt is outside the destructive confirmation")
    #expect(
      failureAlert.lowerBound < retry.lowerBound && retry.lowerBound < retryAttempt.lowerBound,
      "the retry attempt is outside the canonical failure alert")
    #expect(
      retryAttempt.upperBound < invocation.lowerBound,
      "confirmation and retry do not share the one model-sign-out implementation")

    // The trigger sets the flag; it must not also perform the action.
    let trigger = try #require(source.range(of: "isConfirmingSignOut = true"))
    #expect(trigger.lowerBound > retryAttempt.upperBound && trigger.upperBound < invocation.lowerBound)
  }

  @Test("a failed setup sign-out publishes the canonical retryable failure")
  func failedSignOutPublishesCanonicalRetryableFailure() throws {
    let source = try ViewSourceScan.executableText(ofFileNamed: "SetupFlowView.swift")

    #expect(source.contains("if await model.signOut() == false"))
    #expect(source.contains("isShowingSignOutFailure = true"))
    #expect(source.contains("SettingsCopy.logoutFailedTitle"))
    #expect(source.contains("SettingsCopy.logoutFailedMessage"))
    #expect(source.contains("SettingsCopy.retryLogout"))
  }

  /// The confirmation uses Settings' wording. Two wordings for one consequence drift apart, so
  /// this fails if setup grows a private copy.
  @Test("the confirmation reuses the canonical logout copy")
  func confirmationReusesSettingsCopy() throws {
    let source = try ViewSourceScan.executableText(ofFileNamed: "SetupFlowView.swift")

    for reference in [
      "SettingsCopy.logoutTitle", "SettingsCopy.logoutMessage", "SettingsCopy.confirmLogout",
      "SettingsCopy.logoutFailedTitle", "SettingsCopy.logoutFailedMessage",
      "SettingsCopy.retryLogout", "SettingsCopy.cancel",
    ] {
      #expect(source.contains(reference), "the confirmation does not use \(reference)")
    }

    #expect(
      SettingsCopy.logoutMessage.contains("downloaded book"),
      "the shared logout copy stopped naming what logout removes")
  }
}
