import Testing

@testable import AdSkip

/// A kept range's start moves back to a sponsor phrase ("This episode is brought to you by…") up to
/// 90 s before it, in strict mode: the phrase needs a subject, or must be a word from our sponsors.
@Suite struct SponsorPhraseStartTests {
  /// Programme ending 10 s before the phrase (at 100 s by default), sponsor copy, and a kept range
  /// from 120 s.
  private static let range = KeptRange(start: 120, end: 150, meanAdProbability: 0.8, endsItem: false)

  /// `text`'s words, 0.3 s apart, from `start`.
  private static func spoken(_ text: String, from start: Double) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { i, word in
      TranscriptWord(text: String(word), start: start + Double(i) * 0.3, end: start + Double(i) * 0.3 + 0.25)
    }
  }

  private static func transcript(
    _ phrase: String, at start: Double = 100, silences: [Silence] = []
  ) -> PreparedTranscript {
    Fixture.prepared(
      Fixture.words("talk", count: 20, from: start - 20) + spoken(phrase, from: start)
        + Fixture.words("copy", count: 30, from: start + 4) + Fixture.words("ad", count: 60, from: 120),
      silences: silences)
  }

  private static func proposals(
    _ transcript: PreparedTranscript, kept: [KeptRange] = [range], showTitle: String? = nil,
    isTombstoned: (UInt64) -> Bool = { _ in false }
  ) -> [SponsorPhraseStart.Proposal] {
    SponsorPhraseStart.proposals(
      for: kept, in: transcript, showTitle: showTitle, isTombstoned: isTombstoned)
  }

  @Test(arguments: [
    "This episode is brought to you by Acme.",
    "Today's episode is sponsored by Acme.",
    "This podcast is supported by Acme.",
    "This episode is powered by Acme.",
    "The show is also brought to you by Acme.",
    "episode is brought to you by Acme.",
  ])
  func aSubjectAndATriggerStartTheRangeAtTheSentenceHead(phrase: String) {
    #expect(Self.proposals(Self.transcript(phrase)) == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func aWordFromOurSponsorsStartsAtItsLeadIn() {
    #expect(
      Self.proposals(Self.transcript("And now a quick word from our sponsors, Acme."))
        == [.init(keptIndex: 0, starts: [100])])
    #expect(
      Self.proposals(Self.transcript("A word from our sponsor."))
        == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func aBarePhraseMidSentenceDoesNotAnchor() {
    // "…and it's brought to you by our friends at Acme": the host's own segue (strict mode).
    #expect(Self.proposals(Self.transcript("and it's brought to you by our friends at Acme.")).isEmpty)
    #expect(Self.proposals(Self.transcript("brought to you by Acme.")).isEmpty)
  }

  @Test func aPauseInsideThePhraseBreaksIt() {
    let words =
      Self.spoken("this episode is brought to you", from: 100) + Self.spoken("by Acme", from: 103)
      + Fixture.words("ad", count: 60, from: 120)
    #expect(Self.proposals(Fixture.prepared(words)).isEmpty)
  }

  @Test func aPauseBeforeTheSubjectStartsAtTheSubject() {
    // "This" is 1.2 s before "episode", so the head is "episode".
    let words =
      Self.spoken("this", from: 98.5) + Self.spoken("episode is brought to you by Acme", from: 100)
      + Fixture.words("ad", count: 60, from: 120)
    #expect(Self.proposals(Fixture.prepared(words)) == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func aPhraseInsideAKeptRangeIsIgnored() {
    let earlier = KeptRange(start: 95, end: 101, meanAdProbability: 0.8, endsItem: false)
    #expect(
      Self.proposals(Self.transcript("This episode is brought to you by Acme."), kept: [earlier, Self.range]).isEmpty)
  }

  @Test func theStartMovesBackAtMostNinetySeconds() {
    let atLimit = Self.transcript("This episode is brought to you by Acme.", at: 30)
    #expect(Self.proposals(atLimit) == [.init(keptIndex: 0, starts: [30])])
    let beyond = Self.transcript("This episode is brought to you by Acme.", at: 29.9)
    #expect(Self.proposals(beyond).isEmpty)
  }

  @Test func everyAnchorBeforeOneRangeIsOfferedEarliestFirst() {
    let words =
      Fixture.words("talk", count: 20, from: 80) + Self.spoken("a word from our sponsors", from: 100)
      + Self.spoken("this episode is brought to you by Acme", from: 103)
      + Fixture.words("ad", count: 60, from: 120)
    #expect(Self.proposals(Fixture.prepared(words)) == [.init(keptIndex: 0, starts: [100, 103])])
  }

  @Test func theRangeIsTheFirstToStartAfterThePhrase() {
    // A range starting inside the phrase is not the one it opens; the next range is.
    let inside = KeptRange(start: 101, end: 101.5, meanAdProbability: 0.8, endsItem: false)
    let later = KeptRange(start: 200, end: 230, meanAdProbability: 0.8, endsItem: false)
    #expect(
      Self.proposals(Self.transcript("This episode is brought to you by Acme."), kept: [later, Self.range, inside])
        == [.init(keptIndex: 1, starts: [100])])
  }

  @Test func aRangeWithNoPhraseBeforeItGetsNothing() {
    #expect(Self.proposals(Fixture.prepared(Fixture.words("ad", count: 60, from: 120))).isEmpty)
  }

  @Test func aTombstonedStretchIsNotExtendedOver() {
    let transcript = Self.transcript("This episode is brought to you by Acme.")
    let bridged = Set(transcript.shingles.filter { $0.start >= 104 && $0.end < 120 }.map(\.hash))
    #expect(Self.proposals(transcript, isTombstoned: { bridged.contains($0) }).isEmpty)
    // A tombstone inside the range itself is the range's business, not the extension's.
    let inside = Set(transcript.shingles.filter { $0.start >= 120 }.map(\.hash))
    #expect(
      Self.proposals(transcript, isTombstoned: { inside.contains($0) })
        == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func theStartRunsBackOverWordlessAudioToASilence() {
    let phrase = "This episode is brought to you by Acme."
    #expect(
      Self.proposals(Self.transcript(phrase, silences: [Silence(start: 95, end: 98)]))
        == [.init(keptIndex: 0, starts: [98])])
    // A silence ending just after the phrase starts never moves the start later.
    #expect(
      Self.proposals(Self.transcript(phrase, silences: [Silence(start: 98, end: 100.3)]))
        == [.init(keptIndex: 0, starts: [100])])
    // A word between the silence and the phrase keeps the phrase's start.
    #expect(
      Self.proposals(Self.transcript(phrase, silences: [Silence(start: 85, end: 86)]))
        == [.init(keptIndex: 0, starts: [100])])
  }
  // MARK: - Revision 6: sentence-headed forms

  /// `transcript`, with the programme's last sentence ending just before the phrase, so the phrase
  /// opens a sentence.
  private static func afterASentence(_ phrase: String, at start: Double = 100) -> PreparedTranscript {
    Fixture.prepared(
      Fixture.words("talk", count: 20, from: start - 20) + spoken("and that was that.", from: start - 1.5)
        + spoken(phrase, from: start) + Fixture.words("copy", count: 30, from: start + 6)
        + Fixture.words("ad", count: 60, from: 120))
  }

  @Test(arguments: [
    "The Dollop is brought to you by Acme.",
    "How to Fail is also brought to you by Acme.",
    "This ad is brought to you by Acme.",
    "The following conversation is brought to you by Acme.",
    "Gareth Reynolds, the Dollop is brought to you by Acme.",
  ])
  func anyShortSubjectOpeningASentenceAnchorsBroughtToYouBy(phrase: String) {
    #expect(Self.proposals(Self.afterASentence(phrase)) == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func broughtToUsByIsATrigger() {
    // Huberman's reads; a subject anchors it with or without a sentence boundary.
    #expect(
      Self.proposals(Self.transcript("Today's episode is also brought to us by Acme."))
        == [.init(keptIndex: 0, starts: [100])])
  }

  @Test(arguments: [
    "Support for this episode of The Rest is Money comes from Acme.",
    "Support for the show comes from Acme.",
    "And support for Today Explained comes from Acme.",
  ])
  func supportForSomethingComesFromAnchorsAtTheSentenceHead(phrase: String) {
    #expect(Self.proposals(Self.afterASentence(phrase)) == [.init(keptIndex: 0, starts: [100])])
  }

  @Test(arguments: [
    "Now is a great time to thank our friends at Acme.",
    "We want to thank our brand new presenting partner, Acme.",
    "Listeners, this is a great time to thank one of our favourite companies, Acme.",
    "Thank you to our sponsor, Acme.",
  ])
  func thankingOurPartnersAnchorsAtTheSentenceHead(phrase: String) {
    #expect(Self.proposals(Self.afterASentence(phrase)) == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func forSponsoringAnchorsAtTheSentenceHead() {
    #expect(
      Self.proposals(Self.afterASentence("Thanks to Acme for sponsoring the pod."))
        == [.init(keptIndex: 0, starts: [100])])
  }

  @Test(arguments: [
    // A sentence-headed phrase needs the sentence to start there.
    "the Dollop is brought to you by Acme.",
    "support for this episode comes from Acme.",
    "now is a great time to thank our friends at Acme.",
  ])
  func aSentenceHeadedFormMidSentenceDoesNotAnchor(phrase: String) {
    // `transcript` puts programme words, with no full stop, straight before the phrase.
    let words =
      Fixture.words("talk", count: 20, from: 90) + Self.spoken(phrase, from: 100)
      + Fixture.words("ad", count: 60, from: 120)
    #expect(Self.proposals(Fixture.prepared(words)).isEmpty)
  }

  @Test(arguments: [
    // Programme the corpus showed near ads: only "brought to you by" takes any subject.
    "Um, and he was supported by his second wife.",
    "And a lot of people believe this thing is being sponsored by the party.",
    // The host's segue is too far into its sentence.
    "Then we do the hot seat and finish with questions and the whole thing is brought to you by Acme.",
    // A sponsored segment title, and a sponsor named in passing.
    "Welcome to part of my take, presented by Acme.",
    "Places like our sponsors over at Acme have it at sixty nine percent.",
    // "Thank" with no partner, sponsor or friends at.
    "I want to thank our listeners for every question.",
  ])
  func programmeNearAnAdDoesNotAnchor(phrase: String) {
    #expect(Self.proposals(Self.afterASentence(phrase)).isEmpty)
  }

  @Test func supportForReachesComesFromWithinEightWords() {
    #expect(
      Self.proposals(Self.afterASentence("Support for one two three four five six seven eight comes from Acme."))
        == [.init(keptIndex: 0, starts: [100])])
    #expect(
      Self.proposals(Self.afterASentence("Support for one two three four five six seven eight nine comes from Acme."))
        .isEmpty)
  }

  // MARK: - Revision 8: the show's own name

  @Test(arguments: [
    "The Rest Is Money is powered by Acme.",
    "Rest is money is also powered by Acme.",
    "The Rest Is Money is sponsored by Acme.",
    "The Rest Is Money was proudly supported by Acme.",
  ])
  func theShowsNameOpeningASentenceAnchorsEveryTrigger(phrase: String) {
    #expect(
      Self.proposals(Self.afterASentence(phrase), showTitle: "The Rest Is Money")
        == [.init(keptIndex: 0, starts: [100])])
  }

  @Test func anotherSubjectStillNeedsBroughtToYouBy() {
    let phrase = "The Rest Is Money is powered by Acme."
    #expect(Self.proposals(Self.afterASentence(phrase)).isEmpty)
    #expect(Self.proposals(Self.afterASentence(phrase), showTitle: "The Rest Is Politics").isEmpty)
    #expect(Self.proposals(Self.afterASentence(phrase), showTitle: "  ").isEmpty)
    #expect(
      Self.proposals(Self.afterASentence("Um, and he was supported by his second wife."), showTitle: "He")
        .isEmpty)
  }

  @Test func theShowsNameMidSentenceDoesNotAnchor() {
    let words =
      Fixture.words("talk", count: 20, from: 90) + Self.spoken("the rest is money is powered by Acme", from: 100)
      + Fixture.words("ad", count: 60, from: 120)
    #expect(Self.proposals(Fixture.prepared(words), showTitle: "The Rest Is Money").isEmpty)
  }
}
