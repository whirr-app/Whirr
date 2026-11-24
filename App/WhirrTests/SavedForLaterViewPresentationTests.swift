import AppModel
import Testing

@testable import Whirr

@Suite("Saved for Later view source")
struct SavedForLaterViewPresentationTests {
  @Test("saved-shelf swipe buttons are also available from one context menu")
  func savedSwipeButtonsHaveContextMenuAlternative() {
    let buttons = ItemSwipePresentation.buttons(
      for: [.play, .removeFromSaved, .removeDownload])

    #expect(buttons.map(\.label) == ["Play", "Unsave", "Remove"])
    #expect(buttons.last?.role == .destructive)

    // A policy may place the same button on both edges. The menu is their union, so it must
    // collapse by identity or the same action appears twice.
    #expect(SavedForLaterView.uniqueButtons(buttons + buttons).map(\.id) == buttons.map(\.id))
  }

  /// The scene-root `AppChrome.tint` outranks `ButtonRole.destructive`, so a swipe button with no
  /// fill of its own renders near-white in dark mode. Every capsule comes from a table that names
  /// one. Native selection toolbar buttons may still use the system destructive role.
  @Test("no saved-shelf swipe button is left to inherit the scene tint")
  func everySavedSwipeButtonStatesItsFill() throws {
    // ItemSwipeAction is not CaseIterable. Keep this list in step with the enum cases: each new
    // action needs its expected tint here.
    let expected: [(ItemSwipeAction, PodcastEpisodeSwipeTint)] = [
      (.play, .playback),
      (.playNext, .playback),
      (.read, .playback),
      (.removeFromSaved, .savedRemoval),
      (.download, .download),
      (.removeDownload, .remove),
      (.markAsFinished, .finished),
      (.resetProgress, .reset),
    ]

    for (action, tint) in expected {
      #expect(
        ItemSwipePresentation.button(for: action).tint == tint,
        "unexpected tint for \(action)"
      )
    }

    let saved = try ViewSourceScan.source(declaring: "SavedForLaterView")
    let text = try ViewSourceScan.executableText(of: saved)
    let start = try #require(text.range(of: "private func savedSwipe<Content: View>"))
    let end = try #require(text.range(of: "static func uniqueButtons", range: start.upperBound..<text.endIndex))
    #expect(text[start.lowerBound..<end.lowerBound].contains("Button(role: .destructive)") == false)
  }

  // LibraryShellView diverts `.homeMore` Saved for Later to its dedicated destination before the
  // generic `HomeMoreView` route.
  @Test("the shell diverts Saved for Later before the generic more view")
  func libraryShellRoutesSavedForLaterToDedicatedView() throws {
    let text = try ViewSourceScan.libraryShellText()
    let homeMore = try #require(text.range(of: "case .homeMore(let section, let filter):"))
    let routeBody = text[homeMore.lowerBound...]
    let savedRoute = try #require(routeBody.range(of: "section == .savedForLater"))
    let genericView = try #require(routeBody.range(of: "HomeMoreView("))

    #expect(savedRoute.lowerBound < genericView.lowerBound)
    #expect(routeBody.contains("savedForLaterDestination(filter: filter)"))
  }

}
