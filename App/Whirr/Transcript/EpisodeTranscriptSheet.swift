import AppModel
import PlayerCore
import SwiftUI

/// An episode's transcript: its progress, and the text as it
/// arrives. The sentence being spoken is highlighted and kept in view until
/// the listener scrolls; tapping a sentence plays from it.
struct EpisodeTranscriptSheet: View {
  @Bindable var model: EpisodeTranscriptModel
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  /// The show's colour for the sheet's actions, and the ink that reads on it.
  let accent: TranscriptAccent
  let chapters: () -> [PlaybackChapter]

  @Environment(\.dismiss) private var dismiss
  @AppStorage(TranscriptBatteryConfirmation.skipKey) private var skipsBatteryConfirmation = false
  @State private var isConfirmingOnBattery = false

  var body: some View {
    NavigationStack {
      Group {
        if model.transcript.paragraphs.isEmpty {
          TranscriptPlaceholder(model: model, accent: accent, onTranscribe: requestTranscription)
        } else {
          transcriptText
            .searchable(text: $model.searchQuery, prompt: Text("Search Transcript"))
        }
      }
      .navigationTitle(model.isMarking ? TranscriptAdMarkingCopy.menuTitle : "Transcript")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if model.isMarking == false {
          ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { dismiss() }
              .tint(.primary)
          }
        }
        let marking = TranscriptAdMarkingMenu.presentation(
          availability: model.markingAvailability, isReady: model.state == .ready,
          isMarking: model.isMarking)
        if marking != .absent {
          ToolbarItem(placement: .topBarTrailing) { marking.menu(model: model) }
        }
        if model.isMarking == false {
          ToolbarItem(placement: .topBarTrailing) {
            TranscriptPlayPauseButton(playback: playback, itemID: itemID, episodeID: episodeID)
          }
        }
        let searchMatch = model.isMarking ? nil : model.currentMatch
        let bottomBar = TranscriptBottomBar.content(
          hasMatches: searchMatch != nil && model.matches.isEmpty == false,
          breakCount: model.adBreaks.count)
        if bottomBar == .search, let current = searchMatch {
          ToolbarItemGroup(placement: .bottomBar) {
            Button("Previous Match", systemImage: "chevron.up") { model.previousMatch() }
              .tint(.primary)
            Text("\(current + 1) of \(model.matches.count)")
              .font(.footnote.monospacedDigit())
            Button("Next Match", systemImage: "chevron.down") { model.nextMatch() }
              .tint(.primary)
          }
        } else if bottomBar == .adBreaks {
          TranscriptAdBreakToolbar(model: model)
        }
      }
      .transcriptAdMarkingChrome(model: model, accent: accent)
    }
    .background {
      TranscriptPlayheadFeed(model: model, playback: playback, itemID: itemID, episodeID: episodeID)
    }
    // The sheet follows status itself while it is up: the page's own follow is cancelled when the
    // sheet covers it, which left this showing whatever arrived before.
    .task { await model.run() }
    .alert(
      TranscriptBatteryConfirmation.title, isPresented: $isConfirmingOnBattery
    ) {
      Button(TranscriptBatteryConfirmation.transcribe) { model.transcribe() }
      Button(TranscriptBatteryConfirmation.transcribeAndStopAsking) {
        skipsBatteryConfirmation = true
        model.transcribe()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(TranscriptBatteryConfirmation.message)
    }
  }

  /// The text, with a slim progress strip above it while the rest is still being made.
  private var transcriptText: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          let headings = model.transcript.chapterHeadings(
            chapters().compactMap { chapter in chapter.title.map { (start: chapter.start, title: $0) } })
          ForEach(TranscriptAdBlocks.blocks(model.transcript.paragraphs), id: \.id) { block in
            if let ad = block.ad {
              // One ad is one group: the header once, and one rule for the whole height.
              VStack(alignment: .leading, spacing: 22) {
                TranscriptAdHeader(range: ad, onUndo: { model.undoAd($0) })
                ForEach(block.entries, id: \.paragraph.id) { entry in
                  paragraphRow(entry.paragraph, index: entry.index, headings: headings)
                }
              }
              .transcriptAdRule(accent: accent.fill)
            } else {
              ForEach(block.entries, id: \.paragraph.id) { entry in
                paragraphRow(entry.paragraph, index: entry.index, headings: headings)
              }
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        TranscriptProgressStrip(model: model, accent: accent, onTranscribe: requestTranscription)
      }
      .onScrollPhaseChange { _, phase in
        if phase == .interacting { model.stopFollowing() }
      }
      .onChange(of: model.currentSentenceIndex) { _, _ in
        guard model.isFollowing else { return }
        scrollToCurrentSentence(proxy)
      }
      .onChange(of: model.isFollowing) { _, isFollowing in
        if isFollowing { scrollToCurrentSentence(proxy) }
      }
      // To the top, from the paragraph before the break: what led into it shows above the ads.
      .onChange(of: model.adBreakJump) { _, jump in
        guard let jump else { return }
        withAnimation { proxy.scrollTo(jump.paragraphID, anchor: .top) }
      }
      .onChange(of: model.currentMatch) { _, _ in
        guard let sentence = currentMatchSentence, let paragraph = paragraphID(containing: sentence)
        else { return }
        withAnimation { proxy.scrollTo(paragraph, anchor: .center) }
      }
      .overlay(alignment: .bottom) {
        if model.isFollowing == false, model.currentSentenceIndex != nil, model.isMarking == false {
          TranscriptNowButton { model.resumeFollowing() }
        }
      }
    }
  }

  private func paragraphRow(
    _ paragraph: TranscriptParagraphs.Paragraph, index: Int, headings: [Int: String]
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let heading = headings[index] {
        Text(heading)
          .font(.title3.bold())
          .padding(.top, index == 0 ? 0 : 14)
          .accessibilityAddTraits(.isHeader)
      }
      if model.isMarking == false {
        TranscriptTimestampButton(start: paragraph.start) {
          model.play(fromSentence: paragraph.firstSentenceIndex)
        }
      }
      TranscriptParagraphView(
        paragraph: paragraph,
        highlight: highlight(in: paragraph),
        accent: accent.fill,
        // Through the model's one entry, which reads the mode when the tap lands: this closure
        // must not capture `isMarking`, since the view is equatable on its paragraph and highlight.
        onTap: { model.sentenceTapped($0) },
        onRowTap: { model.paragraphTapped(firstSentence: $0) },
        onStartAd: { model.setMarkingStart(sentence: $0) },
        onEndAd: { model.setMarkingEnd(sentence: $0) },
        onUndo: { model.undoAd($0) }
      )
      .equatable()
    }
    .id(paragraph.id)
  }

  /// Starts at once on external power, or once the listener has said not to ask; on battery it asks
  /// first, since a long episode keeps the Neural Engine busy for minutes.
  private func requestTranscription() {
    if skipsBatteryConfirmation || TranscriptBatteryConfirmation.isOnExternalPower() {
      model.transcribe()
    } else {
      isConfirmingOnBattery = true
    }
  }

  private var currentMatchSentence: Int? {
    model.currentMatch.map { model.matches[$0] }
  }

  private func highlight(in paragraph: TranscriptParagraphs.Paragraph) -> TranscriptParagraphView.Highlight {
    let range = paragraph.firstSentenceIndex..<(paragraph.firstSentenceIndex + paragraph.sentences.count)
    return TranscriptParagraphView.Highlight(
      current: model.currentSentenceIndex.flatMap { range.contains($0) ? $0 : nil },
      matches: Set(model.matches.filter { range.contains($0) }),
      selectedMatch: currentMatchSentence.flatMap { range.contains($0) ? $0 : nil },
      selection: model.markingSelection.flatMap { selection in
        let sentences = range.lowerBound...(range.upperBound - 1)
        return selection.overlaps(sentences) ? selection.clamped(to: sentences) : nil
      },
      isMarking: model.isMarking)
  }

  private func scrollToCurrentSentence(_ proxy: ScrollViewProxy) {
    guard let sentence = model.currentSentenceIndex, let paragraph = paragraphID(containing: sentence)
    else { return }
    withAnimation { proxy.scrollTo(paragraph, anchor: .center) }
  }

  /// The scroll id of the paragraph holding a sentence.
  private func paragraphID(containing sentence: Int) -> Int? {
    model.transcript.paragraphIndex(containingSentence: sentence).map {
      model.transcript.paragraphs[$0].id
    }
  }
}

/// Feeds the playhead to the model. Its own view, so the position tick re-runs this body alone and
/// not the sheet's.
private struct TranscriptPlayheadFeed: View {
  let model: EpisodeTranscriptModel
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?

  var body: some View {
    let time: Double? =
      playback.loadedItemID == itemID && playback.loadedEpisodeID == episodeID
      ? playback.currentTime : nil
    Color.clear
      .onChange(of: time, initial: true) { _, time in
        if let time { model.playheadMoved(to: time) }
      }
  }
}

/// The whole sheet while there is no text yet: what is happening, in the system's empty-state
/// layout, with the one action that applies.
private struct TranscriptPlaceholder: View {
  let model: EpisodeTranscriptModel
  let accent: TranscriptAccent
  let onTranscribe: () -> Void

  var body: some View {
    switch model.state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable:
      ContentUnavailableView(
        "No Transcript", systemImage: "quote.bubble",
        description: Text("Transcripts are made for downloaded episodes of English shows."))
    case .offer:
      ContentUnavailableView {
        Label("No Transcript Yet", systemImage: "quote.bubble")
      } description: {
        Text("Whirr transcribes on this iPhone, and the text appears here as it’s ready.")
      } actions: {
        Button("Transcribe") { onTranscribe() }
          .transcriptPrimaryAction(accent)
      }
    case .needsAsset:
      working("Getting Ready", symbol: "arrow.down.circle", detail: "Downloading the speech model.") {
        Button("Try Again") { model.retryAsset() }
      }
    case .held(.queued, _):
      working("Waiting to Start", symbol: "hourglass", detail: "Another episode is being worked on.") {
        EmptyView()
      }
    case .held(.paused, _):
      working(
        "Paused", symbol: "pause.circle",
        detail: "Low Power Mode is on, or this iPhone is warm. It carries on when it can."
      ) { EmptyView() }
    case .generating(let fraction):
      working(
        "Transcribing", symbol: "waveform", animated: true,
        detail: "\(TranscriptProgressStrip.percent(fraction)) done. The text appears here as it’s ready.",
        fraction: fraction
      ) { EmptyView() }
    case .ready:
      ContentUnavailableView(
        "No Speech Found", systemImage: "waveform.slash",
        description: Text("Whirr didn’t hear any words in this episode."))
    case .failed:
      ContentUnavailableView {
        Label("Couldn’t Transcribe", systemImage: "exclamationmark.bubble")
      } description: {
        Text("Something went wrong while transcribing this episode.")
      } actions: {
        Button("Try Again") { onTranscribe() }
          .transcriptPrimaryAction(accent)
      }
    }
  }

  private func working(
    _ title: String, symbol: String, animated: Bool = false, detail: String,
    fraction: Double? = nil, @ViewBuilder extra: () -> some View
  ) -> some View {
    ContentUnavailableView {
      Label {
        Text(title)
      } icon: {
        Image(systemName: symbol)
          .foregroundStyle(accent.fill)
          .symbolEffect(.variableColor.iterative, isActive: animated)
      }
    } description: {
      VStack(spacing: 14) {
        Text(detail)
        if let fraction {
          ProgressView(value: fraction)
            .tint(accent.fill)
            .frame(maxWidth: 220)
        }
      }
    } actions: {
      HStack {
        extra()
        Button("Cancel") { model.cancel() }
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.capsule)
      .controlSize(.large)
      .tint(.primary)
    }
  }
}
