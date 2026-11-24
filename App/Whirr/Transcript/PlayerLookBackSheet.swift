import AppModel
import DesignSystem
import SwiftUI
import TipKit

/// The page's Look Back: the sheet's model, kept while the listener stays near where it opened so
/// reopening shows the same text.
@MainActor
@Observable
final class PlayerLookBackController {
  private(set) var model: LookBackModel?
  var isPresented = false

  private let makeDependencies: @MainActor () -> LookBackModel.Dependencies

  init(
    makeDependencies: @escaping @MainActor () -> LookBackModel.Dependencies = {
      LookBackComposition.dependencies()
    }
  ) {
    self.makeDependencies = makeDependencies
  }

  /// Pauses the book and raises the sheet, on the previous text when it still answers for the
  /// playhead. A cold launch's restored book is loaded paused first; a failed load raises
  /// nothing, and the player shows why.
  func show(itemID: String, playback: PlaybackModel) async {
    LookBackTip().invalidate(reason: .actionPerformed)
    guard await playback.loadForLookBack(itemID: itemID) else { return }
    let playhead = playback.pauseForLookBack()
    let source = playback.loadedLookBack
    if model?.canBeReused(for: source, playhead: playhead) != true {
      model = LookBackModel(
        source: source, playhead: playhead, dependencies: makeDependencies(),
        play: { [weak playback] offset in playback?.play(fromGlobalOffset: offset) })
    }
    isPresented = true
  }

  /// The page moved to another item: the text no longer answers for anything.
  func discard() {
    isPresented = false
    model = nil
  }
}

/// When the overflow menu offers Look Back.
nonisolated enum PlayerLookBackPresentation {
  /// Every loaded audiobook, downloaded or not: a streamed one opens on why it cannot.
  /// A cold launch's restored audiobook is offered before it loads, so Look Back is there before
  /// the first Play; choosing it loads the book paused.
  static func isOffered(
    itemID: String, episodeID: String?, loadedItemID: String?, loadedEpisodeID: String?,
    isRestoredAudiobook: Bool
  ) -> Bool {
    guard episodeID == nil else { return false }
    return (loadedEpisodeID == nil && loadedItemID == itemID) || isRestoredAudiobook
  }
}

/// The one progress cue a working placeholder shows. Transcribing animates its waveform, which is
/// progress enough; a spinner under it reads as a second, competing load. The still symbols of
/// the other working states need the spinner.
nonisolated enum LookBackWorkingIndicator: Equatable {
  case animatedSymbol
  case spinner

  init(for state: LookBackModel.State) {
    self = state == .transcribing ? .animatedSymbol : .spinner
  }
}

extension View {
  /// The Look Back sheet over the expanded player. Kept out of `ExpandedPlayerView`, as the
  /// transcript sheet is, because that file is at the size where a split is due.
  func playerLookBackSheet(
    _ controller: PlayerLookBackController, itemID: String, playback: PlaybackModel,
    accent: TranscriptAccent
  ) -> some View {
    modifier(
      PlayerLookBackSheetModifier(
        controller: controller, itemID: itemID, playback: playback, accent: accent))
  }
}

private struct PlayerLookBackSheetModifier: ViewModifier {
  @Bindable var controller: PlayerLookBackController
  let itemID: String
  let playback: PlaybackModel
  let accent: TranscriptAccent

  func body(content: Content) -> some View {
    content
      .onChange(of: itemID) { _, _ in controller.discard() }
      // Over the page like Transcript; playback is paused until a sentence is tapped.
      .sheet(isPresented: $controller.isPresented) {
        if let model = controller.model {
          LookBackSheet(model: model, playback: playback, accent: accent)
            .background { LookBackPlaybackFeed(model: model, playback: playback) }
            // Scroll-first, as the transcript sheet: the text is read by scrolling.
            .themedSheet(
              accent: accent.fill, role: .form, detents: [.medium, .large],
              contentInteraction: .scrolls)
        }
      }
  }
}

/// The podcast transcript's reader, running backwards: it
/// opens at the newest sentence with the last few minutes transcribing above it, and Show Earlier
/// at the top transcribes further back. Rows are keyed by start time, not position, so they keep
/// their identity as older chunks arrive above them.
private struct LookBackSheet: View {
  let model: LookBackModel
  let playback: PlaybackModel
  let accent: TranscriptAccent

  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var isConfirmingDownload = false
  @State private var wasBackgrounded = false

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(LookBackCopy.title)
        .navigationSubtitle(
          model.playingFrom.map {
            LookBackCopy.playingFrom(TranscriptTimestamp.text(before: model.playhead, start: $0))
          } ?? ""
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) { dismiss() }
              .tint(.primary)
          }
          if let itemID = model.source?.itemID {
            ToolbarItem(placement: .topBarTrailing) {
              TranscriptPlayPauseButton(
                playback: playback, itemID: itemID, episodeID: nil, isOffered: model.playingFrom != nil)
            }
          }
        }
    }
    .task { await model.appear() }
    .onDisappear { model.disappear() }
    // Foreground only: leaving cancels the chunk in flight, and coming back runs the rest.
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background:
        wasBackgrounded = true
        model.disappear()
      case .active where wasBackgrounded:
        wasBackgrounded = false
        Task { await model.appear() }
      default:
        break
      }
    }
    .sensoryFeedback(.selection, trigger: model.playingFrom)
    .adSkipDownloadConfirmation(
      isPresented: $isConfirmingDownload, message: LookBackCopy.downloadMessage,
      offersWiFiWait: false
    ) { _ in
      Task { await model.installAsset() }
    }
  }

  @ViewBuilder private var content: some View {
    if model.paragraphs.paragraphs.isEmpty {
      placeholder
    } else {
      reader
    }
  }

  /// The whole sheet while there is no text, in the transcript sheet's empty-state layout.
  @ViewBuilder private var placeholder: some View {
    switch model.state {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable(.notDownloaded):
      ContentUnavailableView(
        LookBackCopy.notDownloadedTitle, systemImage: "arrow.down.circle",
        description: Text(LookBackCopy.notDownloadedMessage))
    case .unavailable(.noRecogniser):
      ContentUnavailableView(
        LookBackCopy.noRecogniserTitle, systemImage: "waveform.slash",
        description: Text(LookBackCopy.noRecogniserMessage))
    case .needsAsset:
      ContentUnavailableView {
        Label(LookBackCopy.needsAssetTitle, systemImage: "arrow.down.circle")
      } description: {
        Text(LookBackCopy.needsAssetMessage)
      } actions: {
        Button(LookBackCopy.download) { isConfirmingDownload = true }
          .transcriptPrimaryAction(accent)
      }
    case .installingAsset:
      working(LookBackCopy.needsAssetTitle, symbol: "arrow.down.circle", detail: LookBackCopy.downloading)
    case .waiting:
      working(LookBackCopy.waitingTitle, symbol: "hourglass", detail: LookBackCopy.waiting)
    case .transcribing:
      working(LookBackCopy.transcribing, symbol: "waveform", detail: LookBackCopy.transcribingDetail)
    case .ready:
      ContentUnavailableView {
        Label(LookBackCopy.noSpeech, systemImage: "waveform.slash")
      } description: {
        Text(LookBackCopy.noSpeechDetail)
      } actions: {
        if model.canLoadEarlier {
          Button(LookBackCopy.goFurtherBack) { model.loadEarlier() }
            .transcriptPrimaryAction(accent)
        }
      }
    case .failed(let failure):
      ContentUnavailableView {
        Label(LookBackCopy.failureTitle(failure), systemImage: "exclamationmark.bubble")
      } description: {
        Text(LookBackCopy.failureMessage(failure))
      } actions: {
        Button(LookBackCopy.tryAgain) { model.retry() }
          .transcriptPrimaryAction(accent)
      }
    }
  }

  private func working(_ title: String, symbol: String, detail: String) -> some View {
    let indicator = LookBackWorkingIndicator(for: model.state)
    return ContentUnavailableView {
      Label {
        Text(title)
      } icon: {
        Image(systemName: symbol)
          .foregroundStyle(accent.fill)
          .symbolEffect(.variableColor.iterative, isActive: indicator == .animatedSymbol)
      }
    } description: {
      Text(detail)
    } actions: {
      if indicator == .spinner { ProgressView() }
    }
  }

  private var reader: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          earlierRow
          ForEach(Array(model.paragraphs.paragraphs.enumerated()), id: \.element.start) { index, paragraph in
            row(paragraph, index: index)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
      }
      .defaultScrollAnchor(.bottom)
      .defaultScrollAnchor(.bottom, for: .sizeChanges)
      .onScrollPhaseChange { _, phase in
        if phase == .interacting { model.stopFollowing() }
      }
      // On the sentence, not its index: an older chunk landing above moves the index alone, and
      // scrolling then sends the reader up into the new text and back down.
      .onChange(of: model.highlightedSentenceStart) { _, _ in
        guard model.isFollowing else { return }
        scrollToHighlight(proxy)
      }
      .onChange(of: model.isFollowing) { _, isFollowing in
        if isFollowing { scrollToHighlight(proxy) }
      }
      .overlay(alignment: .bottom) {
        if model.isFollowing == false, model.highlightedSentenceIndex != nil {
          TranscriptNowButton { model.resumeFollowing() }
        }
      }
    }
  }

  /// Above the oldest text: Show Earlier, what is happening further back, or why it goes no
  /// further. A button, not a load on reaching the top: the older text lands just below this row,
  /// so the row never leaves the screen and an automatic load would run on to the limit. Tapped,
  /// the earlier text appears right under it, to be read down into what was already there.
  private var earlierRow: some View {
    Group {
      switch model.state {
      case .waiting:
        earlierStatus(LookBackCopy.waiting, isWorking: true)
      case .failed(let failure):
        HStack(alignment: .firstTextBaseline) {
          Label(LookBackCopy.failureTitle(failure), systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: WhirrSpacing.small)
          Button(LookBackCopy.tryAgain) { model.retry() }
            .font(.footnote.weight(.semibold))
            .tint(.primary)
        }
      case .ready where model.reachesStartOfBook:
        earlierStatus(LookBackCopy.reachesStart, isWorking: false)
      case .ready where model.reachesLimit:
        earlierStatus(LookBackCopy.reachesLimit, isWorking: false)
      case .ready:
        Button(LookBackCopy.showEarlier, systemImage: "chevron.up") { model.loadEarlier() }
          .font(.footnote.weight(.semibold))
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .tint(.primary)
          .accessibilityHint(LookBackCopy.showEarlierHint)
      case .loading, .unavailable, .needsAsset, .installingAsset, .transcribing:
        earlierStatus(LookBackCopy.transcribingEarlier, isWorking: true)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func earlierStatus(_ text: String, isWorking: Bool) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      if isWorking { ProgressView() }
      Text(text)
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .accessibilityElement(children: .combine)
  }

  private func row(_ paragraph: TranscriptParagraphs.Paragraph, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let heading = model.chapterHeadings[index] {
        Text(heading)
          .font(.title3.bold())
          .padding(.top, index == 0 ? 0 : 14)
          .accessibilityAddTraits(.isHeader)
      }
      TranscriptTimestampButton(start: paragraph.start, countingBackFrom: model.playhead) {
        model.playSentence(at: paragraph.firstSentenceIndex)
      }
      TranscriptParagraphView(
        paragraph: paragraph, highlight: highlight(in: paragraph), accent: accent.fill,
        onTap: { model.playSentence(at: $0) }
      )
      .equatable()
    }
    .id(paragraph.start)
  }

  /// The newest sentence until one is tapped, then the one playing.
  private func highlight(in paragraph: TranscriptParagraphs.Paragraph) -> TranscriptParagraphView.Highlight {
    let range = paragraph.firstSentenceIndex..<(paragraph.firstSentenceIndex + paragraph.sentences.count)
    return TranscriptParagraphView.Highlight(
      current: model.highlightedSentenceIndex.flatMap { range.contains($0) ? $0 : nil },
      matches: [], selectedMatch: nil, selection: nil)
  }

  private func scrollToHighlight(_ proxy: ScrollViewProxy) {
    guard let sentence = model.highlightedSentenceIndex,
      let index = model.paragraphs.paragraphIndex(containingSentence: sentence)
    else { return }
    withAnimation { proxy.scrollTo(model.paragraphs.paragraphs[index].start, anchor: .center) }
  }
}

/// Feeds the player's position to the model, so the sentence playing after a tap is the one
/// highlighted. Its own view, so the position tick re-runs this body alone and not the sheet's.
private struct LookBackPlaybackFeed: View {
  let model: LookBackModel
  let playback: PlaybackModel

  var body: some View {
    let time: Double? =
      playback.loadedItemID == model.source?.itemID && playback.loadedEpisodeID == nil
      ? playback.currentTime : nil
    Color.clear
      .onChange(of: time) { _, time in
        if let time { model.playbackMoved(to: time) }
      }
  }
}
