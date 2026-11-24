import Foundation
import Testing

@testable import AppModel

/// The item detail hero's tappable metadata: an author/narrator string splits into one link per
/// person (not one dead query for the joined string), a series name keeps its sequence suffix on
/// screen but drops it from the lookup value, and every link carries the destination to push.
@Suite struct ItemMetadataLinkPresentationTests {

  @Test func semanticDestinationsMapToDirectRoutes() {
    #expect(
      ItemMetadataNavigationPresentation.route(for: .author(name: "Matt Dinniman"))
        == .authorName(name: "Matt Dinniman"))
    #expect(
      ItemMetadataNavigationPresentation.route(for: .series(name: "Dungeon Crawler Carl"))
        == .seriesName(name: "Dungeon Crawler Carl"))
    #expect(
      ItemMetadataNavigationPresentation.route(for: .narrator(name: "Jeff Hays"))
        == .narrator(name: "Jeff Hays"))
  }

  // MARK: - People

  @Test("a dual narrator credit becomes one link per person")
  func dualNarratorCreditSplitsPerPerson() {
    #expect(
      ItemMetadataLinkPresentation.personLinks("Travis Baldree, Jeff Hays", role: .narrator) == [
        ItemMetadataLink(
          displayName: "Travis Baldree", destination: .narrator(name: "Travis Baldree")),
        ItemMetadataLink(displayName: "Jeff Hays", destination: .narrator(name: "Jeff Hays")),
      ])
  }

  @Test("a single name becomes one link")
  func singleNameBecomesOneLink() {
    #expect(
      ItemMetadataLinkPresentation.personLinks("Matt Dinniman", role: .author) == [
        ItemMetadataLink(displayName: "Matt Dinniman", destination: .author(name: "Matt Dinniman"))
      ])
  }

  @Test("surrounding whitespace and empty segments are dropped")
  func whitespaceAndEmptySegmentsAreDropped() {
    #expect(
      ItemMetadataLinkPresentation.personLinks(
        "  Ann Leckie ,, Adjoa Andoh ,  ", role: .author) == [
          ItemMetadataLink(displayName: "Ann Leckie", destination: .author(name: "Ann Leckie")),
          ItemMetadataLink(displayName: "Adjoa Andoh", destination: .author(name: "Adjoa Andoh")),
        ])
  }

  @Test("a repeated name is listed once", arguments: ["Jeff Hays, Jeff Hays", "Jeff Hays,Jeff Hays"])
  func repeatedNameIsListedOnce(value: String) {
    #expect(ItemMetadataLinkPresentation.personLinks(value, role: .narrator).count == 1)
  }

  @Test("nothing to link", arguments: [nil, "", "   ", ","])
  func nothingToLink(value: String?) {
    #expect(ItemMetadataLinkPresentation.personLinks(value, role: .author).isEmpty)
  }

  // MARK: - Series

  @Test("a series keeps its sequence on screen and drops it from the query")
  func seriesKeepsSequenceOnScreenAndDropsItFromTheQuery() {
    #expect(
      ItemMetadataLinkPresentation.seriesLink("Dungeon Crawler Carl #8")
        == ItemMetadataLink(
          displayName: "Dungeon Crawler Carl #8",
          destination: .series(name: "Dungeon Crawler Carl")))
  }

  @Test("a decimal sequence is dropped too")
  func decimalSequenceIsDroppedToo() {
    #expect(
      ItemMetadataLinkPresentation.seriesLink("The Expanse #3.5")?.destination
        == .series(name: "The Expanse"))
  }

  @Test("a series without a sequence queries its whole name")
  func seriesWithoutSequenceQueriesItsWholeName() {
    #expect(
      ItemMetadataLinkPresentation.seriesLink("Wayfarers")
        == ItemMetadataLink(displayName: "Wayfarers", destination: .series(name: "Wayfarers")))
  }

  /// Stripping must never leave nothing to search for.
  @Test("a series named only by its sequence keeps that as the query")
  func seriesNamedOnlyByItsSequenceKeepsThatAsTheQuery() {
    #expect(ItemMetadataLinkPresentation.seriesLink("#3")?.destination == .series(name: "#3"))
  }

  /// A series name is one destination even when it contains a comma. Only people split.
  @Test("a comma in a series name does not split it")
  func commaInASeriesNameDoesNotSplitIt() {
    #expect(
      ItemMetadataLinkPresentation.seriesLink("Hitchhiker's Guide, The")?.displayName
        == "Hitchhiker's Guide, The")
  }

  @Test("no series", arguments: [nil, "", "   "])
  func noSeries(value: String?) {
    #expect(ItemMetadataLinkPresentation.seriesLink(value) == nil)
  }

  // MARK: - Separators

  @Test("every name but the last is followed by a separator")
  func everyNameButTheLastIsFollowedByASeparator() {
    let links = ItemMetadataLinkPresentation.personLinks(
      "Ann Leckie, Adjoa Andoh, Jeff Hays", role: .author)

    #expect(
      links.indices.map { ItemMetadataLinkPresentation.label(for: links[$0], at: $0, of: links) }
        == ["Ann Leckie,", "Adjoa Andoh,", "Jeff Hays"])
  }

  @Test("a lone name is followed by nothing")
  func aLoneNameIsFollowedByNothing() {
    let links = ItemMetadataLinkPresentation.personLinks("Matt Dinniman", role: .author)

    #expect(
      ItemMetadataLinkPresentation.label(for: links[0], at: 0, of: links) == "Matt Dinniman")
  }

  /// A truncated line's last visible name is not the last name.
  @Test("the name before the overflow count keeps its separator")
  func nameBeforeTheOverflowCountKeepsItsSeparator() {
    let links = ItemMetadataLinkPresentation.personLinks(
      "Ann Leckie, Adjoa Andoh", role: .author)

    #expect(
      ItemMetadataLinkPresentation.label(for: links[1], at: 1, of: links, hasOverflow: true)
        == "Adjoa Andoh,")
    #expect(
      ItemMetadataLinkPresentation.label(for: links[1], at: 1, of: links) == "Adjoa Andoh")
  }

  // MARK: - Overflow

  /// The full-cast case: eight readers is a credit, not a hero.
  @Test("a full cast prints three names and counts the rest")
  func fullCastPrintsThreeNamesAndCountsTheRest() {
    let links = ItemMetadataLinkPresentation.personLinks(
      "Roger Clark, Jay Snyder, Elizabeth Evans, Fred Berman, Brandon Rubin, Kevin T. Collins, "
        + "Lauren Fortgang, Peter Ganim", role: .narrator)

    let visible = ItemMetadataLinkPresentation.visibleLinks(links, isExpanded: false)
    #expect(visible.map(\.displayName) == ["Roger Clark", "Jay Snyder", "Elizabeth Evans"])
    #expect(ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: false) == 5)
    #expect(ItemMetadataLinkPresentation.overflowLabel(hidden: 5) == "+5 more")
  }

  @Test("an opened line prints every name and hides none")
  func openedLinePrintsEveryName() {
    let links = ItemMetadataLinkPresentation.personLinks(
      "Roger Clark, Jay Snyder, Elizabeth Evans, Fred Berman, Brandon Rubin", role: .narrator)

    #expect(ItemMetadataLinkPresentation.visibleLinks(links, isExpanded: true) == links)
    #expect(ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: true) == 0)
  }

  /// Hiding one name to print "+1 more" in its place saves no room and costs a tap.
  @Test(
    "a credit at or one over the limit is printed whole",
    arguments: [
      "Travis Baldree",
      "Travis Baldree, Jeff Hays",
      "Ann Leckie, Adjoa Andoh, Jeff Hays",
      "Ann Leckie, Adjoa Andoh, Jeff Hays, Travis Baldree",
    ])
  func shortCreditIsPrintedWhole(value: String) {
    let links = ItemMetadataLinkPresentation.personLinks(value, role: .narrator)

    #expect(ItemMetadataLinkPresentation.visibleLinks(links, isExpanded: false) == links)
    #expect(ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: false) == 0)
  }

  /// Truncation starts at the first count worth printing, and every hidden name is accounted for.
  @Test("the visible names and the hidden count always add up")
  func visibleNamesAndHiddenCountAddUp() {
    for count in 1...12 {
      let links = (1...count).map {
        ItemMetadataLink(
          displayName: "Reader \($0)", destination: .narrator(name: "Reader \($0)"))
      }
      let visible = ItemMetadataLinkPresentation.visibleLinks(links, isExpanded: false)
      let hidden = ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: false)

      #expect(visible.count + hidden == count)
      #expect(hidden == 0 || hidden >= 2, "a one-name overflow is not worth a control")
      #expect(visible == Array(links.prefix(visible.count)), "names keep their credited order")
    }
  }
}
