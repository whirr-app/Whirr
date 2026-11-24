import AppModel
import Testing

@Suite struct PodcastShowNotesTests {
  @Test("notes with nothing to fold stay whole")
  func plainNotesStayWhole() {
    let notes = PodcastShowNotes("First paragraph.\n\nSecond paragraph.")
    #expect(notes.primary == "First paragraph.\n\nSecond paragraph.")
    #expect(notes.supplementary == nil)
  }

  @Test("everything after the first divider folds, and divider lines are dropped")
  func dividerFoldsTheRest() {
    let notes = PodcastShowNotes(
      "The episode.\n\nMore about it.\n\n__________\n\nJoin our newsletter.\n\n- - -\n\n"
        + "Instagram: @show\nTwitter: @show\n\n***\n\nProducer: Someone")
    #expect(notes.primary == "The episode.\n\nMore about it.")
    #expect(
      notes.supplementary
        == "Join our newsletter.\n\nInstagram: @show\nTwitter: @show\n\nProducer: Someone")
  }

  @Test("a divider on its own line inside a paragraph splits that paragraph")
  func dividerLineInsideParagraph() {
    let notes = PodcastShowNotes("The episode.\n————\nSponsor read.")
    #expect(notes.primary == "The episode.")
    #expect(notes.supplementary == "Sponsor read.")
  }

  @Test("ad paragraphs before any divider fold, keeping their order")
  func adPhrasesFold() {
    let notes = PodcastShowNotes(
      "This episode is sponsored by Acme.\n\nThe episode.\n\n"
        + "Use promo code SHOW for 10% off.\n\nMore about it.\n\n"
        + "Learn more about your ad choices. Visit megaphone.fm/adchoices")
    #expect(notes.primary == "The episode.\n\nMore about it.")
    #expect(
      notes.supplementary
        == "This episode is sponsored by Acme.\n\nUse promo code SHOW for 10% off.\n\n"
        + "Learn more about your ad choices. Visit megaphone.fm/adchoices")
  }

  @Test("a sponsor mentioned mid-sentence is content, not an ad")
  func sponsorMidSentenceIsContent() {
    let text = "We discuss the bill sponsored by Senator Smith."
    #expect(PodcastShowNotes(text).primary == text)
    #expect(PodcastShowNotes(text).supplementary == nil)
  }

  @Test("short dashes and ellipses are not dividers")
  func shortRunsAreNotDividers() {
    let text = "Part one.\n\n--\n\n...\n\nPart two."
    #expect(PodcastShowNotes(text).primary == text)
  }

  @Test("notes that would fold entirely stay whole, minus dividers")
  func neverFoldsEverything() {
    let notes = PodcastShowNotes("__________\n\nSponsored by Acme.\n\nFollow us.")
    #expect(notes.primary == "Sponsored by Acme.\n\nFollow us.")
    #expect(notes.supplementary == nil)
  }

  @Test("a trailing divider with nothing after it folds nothing")
  func trailingDividerFoldsNothing() {
    let notes = PodcastShowNotes("The episode.\n\n__________")
    #expect(notes.primary == "The episode.")
    #expect(notes.supplementary == nil)
  }

  @Test("the Rest Is Politics layout keeps only the episode's own paragraphs up front")
  func megaphoneShapedNotes() {
    let text = """
      Will scrapping the triple lock be electorally perilous for Burnham?

      Join Rory and Alastair as they answer all these questions and more.

      __________

      Go deeper into the world of The Rest Is Politics by signing up for our free newsletter HERE.

      Sponsored by Lloyds. Search Lloyds Corporate.

      __________

      Instagram: @restispolitics

      Producer: Evan Green
      """
    let notes = PodcastShowNotes(text)
    #expect(
      notes.primary
        == "Will scrapping the triple lock be electorally perilous for Burnham?\n\n"
        + "Join Rory and Alastair as they answer all these questions and more.")
    #expect(notes.supplementary?.hasPrefix("Go deeper") == true)
    #expect(notes.supplementary?.hasSuffix("Producer: Evan Green") == true)
  }

  @Test("a recurring paragraph folds wherever it sits, alongside divider and ad rules")
  func boilerplateUnionsWithSingleEpisodeRules() {
    let plug = "Join our newsletter for weekly extras."
    let history = (0..<5).map { "<p>Episode \($0) stands alone here.</p><p>\(plug)</p>" }
    let boilerplate = ShowNotesBoilerplate(descriptions: history)
    let notes = PodcastShowNotes(
      "\(plug)\n\nThe episode.\n\nUse promo code SHOW.\n\n____\n\nCredits.",
      boilerplate: boilerplate)
    #expect(notes.primary == "The episode.")
    #expect(notes.supplementary == "\(plug)\n\nUse promo code SHOW.\n\nCredits.")
  }

  @Test("the never-fold-everything guard holds when boilerplate is the whole note")
  func boilerplateNeverFoldsEverything() {
    let plug = "Join our newsletter for weekly extras."
    let boilerplate = ShowNotesBoilerplate(descriptions: Array(repeating: plug, count: 5))
    let notes = PodcastShowNotes(plug, boilerplate: boilerplate)
    #expect(notes.primary == plug)
    #expect(notes.supplementary == nil)
  }

  @Test("sponsor reads from Megaphone feeds fold on wording alone")
  func megaphoneSponsorReadsFold() {
    let reads = [
      "Brought to you by Plaud. Empire listeners can use code 'EMPIRE' to get a 10% discount on "
        + "their first order at this link: https://uk.plaud.ai/empire",
      "Try ZipRecruiter FOR FREE at\u{00A0}https://ziprecruiter.com/POLITICS",
      "Try Attio for free at attio.com/empire\u{00A0}",
      "Visit https://eightsleep.com/tripus and use the code TRIPUS for up to £200 off the new Pod 6",
      "Summer sale is here: get an annual membership for a third off with code SUMMER26.",
      "\u{2060}\u{2060}This episode is sponsored by eToro. As with all investing, your capital is "
        + "at risk.",
    ]
    for read in reads {
      let notes = PodcastShowNotes("The episode.\n\n\(read)")
      #expect(notes.primary == "The episode.", "\(read)")
      #expect(notes.supplementary == read, "\(read)")
    }
  }

  @Test("content that mentions codes, links, or a call to action stays up front")
  func contentLookalikesStay() {
    let paragraphs = [
      "Can a junior developer be replaced with code an AI wrote? We put it to the test.",
      "Read Jessica's original reporting at https://radiolab.org/stories/four-track-mind.",
      "Visit any ragtime festival and you will hear Bob Milne's name. Usually, Bob sticks to "
        + "playing piano for small groups of ragtime enthusiasts, but he recently caught the "
        + "attention of a neuroscientist, who wrote about it at example.com/bob-milne in a paper "
        + "that changed how we think about attention.",
      "Try to imagine playing four pieces of music at once.",
    ]
    for paragraph in paragraphs {
      let notes = PodcastShowNotes("The episode.\n\n\(paragraph)")
      #expect(notes.supplementary == nil, "\(paragraph)")
    }
  }

  @Test("a short credit line between two folded paragraphs folds with them")
  func sandwichedCreditFolds() {
    // Empire rotates its editor, so this line recurs too rarely for the show-wide signal.
    let notes = PodcastShowNotes(
      "The episode.\n\nSponsored by Plaud.\n\nEditor: Oli Ortega\n\n"
        + "Learn more about your ad choices. Visit podcastchoices.com/adchoices")
    #expect(notes.primary == "The episode.")
    #expect(
      notes.supplementary
        == "Sponsored by Plaud.\n\nEditor: Oli Ortega\n\n"
        + "Learn more about your ad choices. Visit podcastchoices.com/adchoices")
  }

  @Test("only labelled lines with folded paragraphs on both sides fold as credits")
  func sandwichNeedsBothNeighboursAndALabel() {
    let unlabelled = PodcastShowNotes(
      "The episode.\n\nSponsored by Plaud.\n\nPart 2 of 3.\n\nSponsored by Attio.")
    #expect(unlabelled.primary == "The episode.\n\nPart 2 of 3.")

    let oneSided = PodcastShowNotes(
      "The episode.\n\nSponsored by Plaud.\n\nEditor: Oli Ortega\n\nMore about it.")
    #expect(oneSided.primary == "The episode.\n\nEditor: Oli Ortega\n\nMore about it.")
  }

  @Test("a credit fold does not cascade down a run of short lines")
  func sandwichDoesNotCascade() {
    let notes = PodcastShowNotes(
      "The episode.\n\nSponsored by Plaud.\n\nEditor: Oli Ortega\n\nProducer: Anouska Lewis\n\n"
        + "Sponsored by Attio.")
    #expect(notes.primary == "The episode.\n\nEditor: Oli Ortega\n\nProducer: Anouska Lewis")
  }
}
