import AppModel
import Testing

@testable import Whirr

@Suite("Server addresses view presentation")
struct ServerAddressesViewPresentationTests {
  @Test("rows expose scheme glyph and display address")
  func rowCarriesAddressAndScheme() {
    let row = ServerAddressesModel.Row(
      id: 1, displayAddress: "https://books.example.test/library", isActive: false,
      isPreferred: true, reachability: .reached)

    let presentation = ServerAddressesViewPresentation.row(row, rowCount: 2)

    #expect(presentation.securitySymbol == "lock.fill")
    #expect(row.displayAddress == "https://books.example.test/library")
  }

  @Test("active rows expose a checkmark")
  func activeRowCarriesCheckmark() {
    let row = ServerAddressesModel.Row(
      id: 1, displayAddress: "http://lan.example.test:13378", isActive: true,
      isPreferred: false, reachability: .unknown)

    #expect(ServerAddressesViewPresentation.row(row, rowCount: 2).showsActiveCheckmark)
    #expect(ServerAddressesViewPresentation.row(row, rowCount: 2).securitySymbol == "network")
  }

  @Test("the last remaining row cannot be removed")
  func removeIsDisabledForSingleRow() {
    let row = ServerAddressesModel.Row(
      id: 1, displayAddress: "https://books.example.test", isActive: true,
      isPreferred: true, reachability: .unknown)

    #expect(ServerAddressesViewPresentation.row(row, rowCount: 1).canRemove == false)
    #expect(ServerAddressesViewPresentation.row(row, rowCount: 2).canRemove)
  }

  /// A never-probed address is the ordinary state for one just added, and the question-mark glyph
  /// that stood for it read as a help button that did nothing. Only a failed probe earns a badge.
  @Test(
    "only a failed probe shows a status badge",
    arguments: [
      (ServerAddressesModel.Reachability.failed, true),
      (.reached, false),
      (.unknown, false),
    ]
  )
  func unreachableBadgeTracksFailedProbesOnly(
    reachability: ServerAddressesModel.Reachability, showsBadge: Bool
  ) {
    let row = ServerAddressesModel.Row(
      id: 1, displayAddress: "https://books.example.test", isActive: false,
      isPreferred: false, reachability: reachability)

    let presentation = ServerAddressesViewPresentation.row(row, rowCount: 2)

    #expect(presentation.showsUnreachableBadge == showsBadge)
    #expect(presentation.showsStatusLine == showsBadge)
  }

  /// The status line only exists when it has something to say, so a plain row stays one line.
  @Test("a preferred row carries a status line and cannot be set preferred again")
  func preferredRowCarriesStatusLine() {
    let preferred = ServerAddressesModel.Row(
      id: 1, displayAddress: "https://books.example.test", isActive: false,
      isPreferred: true, reachability: .reached)
    let plain = ServerAddressesModel.Row(
      id: 2, displayAddress: "https://other.example.test", isActive: false,
      isPreferred: false, reachability: .reached)

    #expect(ServerAddressesViewPresentation.row(preferred, rowCount: 2).showsPreferredBadge)
    #expect(ServerAddressesViewPresentation.row(preferred, rowCount: 2).showsStatusLine)
    #expect(ServerAddressesViewPresentation.row(preferred, rowCount: 2).canSetPreferred == false)

    #expect(ServerAddressesViewPresentation.row(plain, rowCount: 2).showsStatusLine == false)
    #expect(ServerAddressesViewPresentation.row(plain, rowCount: 2).canSetPreferred)
  }
}
