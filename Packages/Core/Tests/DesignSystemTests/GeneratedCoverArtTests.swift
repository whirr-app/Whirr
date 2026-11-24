import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Generated cover art")
struct GeneratedCoverArtTests {

  @Test("every generated cover uses the fixed orange palette")
  func generatedCoversAreAlwaysOrange() {
    let titles = [
      "The Time Machine", "A Christmas Carol", "Moby-Dick", "Frankenstein", "Dracula",
      "Jane Eyre", "Middlemarch", "Persuasion", "Ulysses", "Walden", "The Odyssey",
      "Crime and Punishment", "Great Expectations", "The Trial", "Wuthering Heights",
      "Heart of Darkness",
    ]
    for title in titles {
      #expect(GeneratedCoverArt(title: title).palette == .orange)
    }
  }

  @Test("the seed combines title and author when both are present")
  func seedCombinesTitleAndAuthor() {
    let withAuthor = GeneratedCoverArt(title: "Selected Poems", author: "Emily Dickinson")
    let withOther = GeneratedCoverArt(title: "Selected Poems", author: "John Keats")
    #expect(withAuthor.seed != withOther.seed)
  }

  @Test("the title alone seeds the art when no author is known")
  func seedFallsBackToTitle() {
    #expect(GeneratedCoverArt(title: "Walden", author: nil).seed == "Walden")
    #expect(GeneratedCoverArt(title: "Walden", author: "  ").seed == "Walden")
  }

  @Test("the display title strips a trailing subtitle clause")
  func displayTitleDropsSubtitle() {
    let art = GeneratedCoverArt(title: "A Christmas Carol: A Ghost Story of Christmas", author: nil)
    #expect(art.displayTitle == "A Christmas Carol")
  }

  @Test("a title that is only a subtitle marker is kept whole")
  func displayTitleKeepsUnsplittableTitles() {
    #expect(GeneratedCoverArt(title: ": Sundered", author: nil).displayTitle == ": Sundered")
  }

  @Test("the author line is nil when the author is blank")
  func authorLineIsNilWhenBlank() {
    #expect(GeneratedCoverArt(title: "Walden", author: "   ").displayAuthor == nil)
    #expect(GeneratedCoverArt(title: "Walden", author: "Thoreau").displayAuthor == "Thoreau")
  }
}
