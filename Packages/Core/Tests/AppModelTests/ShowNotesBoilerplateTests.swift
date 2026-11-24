import AppModel
import Testing

@Suite struct ShowNotesBoilerplateTests {
  private static let plug = "Join our newsletter for weekly extras."

  /// `count` descriptions, the first `recurring` of which carry `plug` beside their own paragraph.
  private static func descriptions(count: Int, recurring: Int, plug: String = plug) -> [String] {
    (0..<count).map { index in
      let own = "Episode \(index) is about something entirely its own."
      return index < recurring ? "<p>\(own)</p><p>\(plug)</p>" : "<p>\(own)</p>"
    }
  }

  @Test("case, whitespace, punctuation, diacritic, and width variants share a key")
  func normalisationVariantsMatch() {
    let variants = [
      "Join our newsletter - for weekly extras!",
      "join  our NEWSLETTER for weekly extras",
      "Jöin our newsletter, for weekly extras.",
      "Ｊｏｉｎ our newsletter for weekly extras",
      "Join our newsletter for weekly extras.",
    ]
    let boilerplate = ShowNotesBoilerplate(descriptions: variants)
    #expect(boilerplate.contains(paragraph: Self.plug))
  }

  @Test("a plug the publisher rewords or re-lists still matches its earlier wording")
  func rewordedPlugsMatch() {
    // Radiolab, September 2026: the newest episode rewrote both standing paragraphs.
    let oldNewsletter =
      "Sign up for our newsletter!! It includes short essays, recommendations, and details about "
      + "other ways to interact with the show. Sign up (https://radiolab.org/newsletter)!"
    let oldSupport =
      "Leadership support for Radiolab’s science programming is provided by the Simons Foundation "
      + "and the John Templeton Foundation. Foundational support for Radiolab was provided by the "
      + "Alfred P. Sloan Foundation."
    let descriptions = (0..<5).map {
      "<p>Episode \($0) stands alone here.</p><p>\(oldNewsletter)</p><p>\(oldSupport)</p>"
    }
    let boilerplate = ShowNotesBoilerplate(descriptions: descriptions)

    #expect(
      boilerplate.contains(
        paragraph: "Our newsletter comes out every Wednesday. It includes short essays, "
          + "recommendations, and details about other ways to interact with the show. "
          + "Sign up (https://radiolab.org/newsletter)!"))
    #expect(
      boilerplate.contains(
        paragraph: "Leadership support for Radiolab’s science programming is provided by the "
          + "Gordon and Betty Moore Foundation, Science Sandbox, a Simons Foundation Initiative, "
          + "and the John Templeton Foundation. Foundational support for Radiolab was provided by "
          + "the Alfred P. Sloan Foundation."))
  }

  @Test("a series' episodes sharing a subject do not match each other")
  func seriesParagraphsStayDistinct() {
    // Empire's six-part Stalin series: each part's summary shares names, never wording.
    let parts = [
      "Fiona Hill is the leading authority on Russia and has been in the room with Putin and "
        + "Trump. She joins Anita Anand and William Dalrymple to discuss how Stalin’s violent "
        + "legacies have impacted Putin's approach to authority.",
      "Antony Beevor wrote the definitive book on the Battle of Stalingrad. He joins Anita Anand "
        + "and William Dalrymple to discuss how Stalin turned the tide against Hitler.",
      "How did Stalin go from a seminary student in Georgia to the ruler of the Soviet Union? "
        + "Anita Anand and William Dalrymple discuss the rise of a tyrant.",
      "Why did Stalin order the murder of Leon Trotsky in Mexico? Anita Anand and William "
        + "Dalrymple discuss the long hunt for the exiled revolutionary.",
      "What drove Stalin’s Great Terror? Anita Anand and William Dalrymple discuss the purges "
        + "that killed hundreds of thousands of Soviet citizens.",
    ]
    let boilerplate = ShowNotesBoilerplate(descriptions: parts)
    #expect(parts.allSatisfy { boilerplate.contains(paragraph: $0) == false })
  }

  @Test("paragraphs under twelve characters never count")
  func shortParagraphsIgnored() {
    let boilerplate = ShowNotesBoilerplate(descriptions: Array(repeating: "<p>Thanks!</p>", count: 10))
    #expect(boilerplate.contains(paragraph: "Thanks!") == false)
  }

  @Test("a paragraph repeated inside one description counts once")
  func countsOncePerDescription() {
    let repeated = "<p>\(Self.plug)</p><p>\(Self.plug)</p><p>\(Self.plug)</p>"
    let descriptions = [repeated] + Self.descriptions(count: 4, recurring: 0)
    #expect(ShowNotesBoilerplate(descriptions: descriptions).contains(paragraph: Self.plug) == false)
  }

  @Test("fewer than five descriptions never fold anything")
  func tooFewSamples() {
    let boilerplate = ShowNotesBoilerplate(descriptions: Self.descriptions(count: 4, recurring: 4))
    #expect(boilerplate.contains(paragraph: Self.plug) == false)
    #expect(boilerplate == .none)
  }

  @Test("at five descriptions, three occurrences fold and two do not")
  func thresholdAtFive() {
    #expect(
      ShowNotesBoilerplate(descriptions: Self.descriptions(count: 5, recurring: 3))
        .contains(paragraph: Self.plug))
    #expect(
      ShowNotesBoilerplate(descriptions: Self.descriptions(count: 5, recurring: 2))
        .contains(paragraph: Self.plug) == false)
  }

  @Test("at twenty descriptions, five occurrences fold and four do not")
  func thresholdAtTwenty() {
    #expect(
      ShowNotesBoilerplate(descriptions: Self.descriptions(count: 20, recurring: 5))
        .contains(paragraph: Self.plug))
    #expect(
      ShowNotesBoilerplate(descriptions: Self.descriptions(count: 20, recurring: 4))
        .contains(paragraph: Self.plug) == false)
  }

  @Test("only the newest twenty descriptions are sampled")
  func windowIsNewestTwenty() {
    // The plug appears only in descriptions 20 to 29, past the window.
    let descriptions =
      Self.descriptions(count: 20, recurring: 0)
      + Array(repeating: "<p>\(Self.plug)</p>", count: 10)
    let boilerplate = ShowNotesBoilerplate(descriptions: descriptions)
    #expect(boilerplate.contains(paragraph: Self.plug) == false)
    #expect(boilerplate.sampleCount == 20)
  }

  @Test("plain-text descriptions split on blank lines like the card does")
  func plainTextDescriptions() {
    let descriptions = (0..<5).map { "Episode \($0) stands alone here.\n\n\(Self.plug)" }
    #expect(ShowNotesBoilerplate(descriptions: descriptions).contains(paragraph: Self.plug))
  }
}
