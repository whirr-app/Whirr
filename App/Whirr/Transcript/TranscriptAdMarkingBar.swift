import AppModel
import SwiftUI

/// What the transcript says about marking an ad. Labels sit in separate texts with no separator
/// character between them.
enum TranscriptAdMarkingCopy {
  static let menuTitle = "Mark an ad"
  static let unavailableReason = "Ad skip has not analysed this episode yet"
  static let lengthLabel = "Length"
  static let markTitle = "Mark as ad"
  static let cancelTitle = "Cancel"
  static let confirmTitle = "Mark"
  static let prompt = "Tap a paragraph in the ad"
  /// After the length when the mark would skip only in this episode, not wherever its audio
  /// recurs.
  static let localOnly = "This episode only"
  static let startAction = "Start ad here"
  static let endAction = "End ad here"

  static func confirmationTitle(seconds: Double) -> String {
    "Mark \(TranscriptTimestamp.text(seconds)) as an ad?"
  }
}

/// Whether the toolbar offers "Mark an ad", and in what state.
enum TranscriptAdMarkingMenu {
  enum Presentation: Equatable {
    case absent
    /// Shown, dimmed, with `reason` beneath the title.
    case disabled(reason: String)
    case enabled
  }

  /// Absent unless the transcript is ready, and while the mode is already on.
  static func presentation(
    availability: TranscriptAdMarking.Availability, isReady: Bool, isMarking: Bool
  ) -> Presentation {
    guard isReady, isMarking == false else { return .absent }
    return switch availability {
    case .hidden: .absent
    case .unavailable: .disabled(reason: TranscriptAdMarkingCopy.unavailableReason)
    case .available: .enabled
    }
  }
}

/// What the navigation bar's subtitle shows for the selection so far.
struct TranscriptAdMarkingBarState: Equatable {
  /// What to do next, until something is selected.
  let prompt: String?
  /// The span as m:ss once something is selected.
  let length: String?
  let canSave: Bool
  /// Whether saving would skip only in this episode.
  let isLocalOnly: Bool

  /// The prompt, or the length once something is selected, then "This episode only" when that
  /// holds; parts are space separated.
  var subtitle: String {
    if let prompt { return prompt }
    guard let length else { return "" }
    let parts =
      [TranscriptAdMarkingCopy.lengthLabel, length]
      + (isLocalOnly ? [TranscriptAdMarkingCopy.localOnly] : [])
    return parts.joined(separator: " ")
  }

  init(seconds: Double?, canSave: Bool, teaches: Bool = true) {
    prompt = seconds == nil ? TranscriptAdMarkingCopy.prompt : nil
    length = seconds.map { TranscriptTimestamp.text($0) }
    self.canSave = seconds != nil && canSave
    isLocalOnly = seconds != nil && teaches == false
  }

  init(model: EpisodeTranscriptModel) {
    self.init(
      seconds: model.markingSeconds, canSave: model.isMarkingLongEnoughToSave,
      teaches: model.markTeaches)
  }
}

extension TranscriptAdMarkingMenu.Presentation {
  /// The trailing toolbar menu.
  @ViewBuilder
  func menu(model: EpisodeTranscriptModel) -> some View {
    switch self {
    case .absent:
      EmptyView()
    case .enabled, .disabled:
      Menu("More", systemImage: "ellipsis") {
        if case .disabled(let reason) = self {
          Button {
          } label: {
            Text(TranscriptAdMarkingCopy.menuTitle)
            Text(reason)
          }
          .disabled(true)
        } else {
          Button(TranscriptAdMarkingCopy.menuTitle, systemImage: "megaphone") {
            model.beginMarking()
          }
        }
      }
      // Chrome, like the close button beside it: a player-raised sheet tints its whole tree with
      // the show's colour, which the menu would otherwise inherit.
      .tint(.primary)
    }
  }
}

/// The navigation bar's side of marking an ad, as in an edit mode: Cancel leading, "Mark as ad"
/// trailing, and what to tap (or the length) as the subtitle. The sheet owns the title and
/// the close button, which Cancel replaces.
private struct TranscriptAdMarkingChrome: ViewModifier {
  let model: EpisodeTranscriptModel
  let accent: TranscriptAccent
  @State private var isConfirmingLongMark = false

  func body(content: Content) -> some View {
    let state = TranscriptAdMarkingBarState(model: model)
    content
      .navigationSubtitle(model.isMarking ? state.subtitle : "")
      .toolbar {
        if model.isMarking {
          ToolbarItem(placement: .topBarLeading) {
            Button(TranscriptAdMarkingCopy.cancelTitle) { model.cancelMarking() }
              .tint(.primary)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(TranscriptAdMarkingCopy.markTitle) { save() }
              .transcriptMarkAction(accent)
              .disabled(state.canSave == false)
          }
        }
      }
      .confirmationDialog(
        TranscriptAdMarkingCopy.confirmationTitle(seconds: model.markingSeconds ?? 0),
        isPresented: $isConfirmingLongMark, titleVisibility: .visible
      ) {
        Button(TranscriptAdMarkingCopy.confirmTitle) { model.confirmMarking() }
        Button(TranscriptAdMarkingCopy.cancelTitle, role: .cancel) {}
      }
  }

  private func save() {
    if model.needsLongMarkConfirmation {
      isConfirmingLongMark = true
    } else {
      model.confirmMarking()
    }
  }
}

extension View {
  /// Marking's navigation bar controls, subtitle and long-mark confirmation.
  func transcriptAdMarkingChrome(model: EpisodeTranscriptModel, accent: TranscriptAccent)
    -> some View
  {
    modifier(TranscriptAdMarkingChrome(model: model, accent: accent))
  }

  fileprivate func transcriptMarkAction(_ accent: TranscriptAccent) -> some View {
    tint(accent.fill)
      .foregroundStyle(accent.ink)
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
  }

  /// While marking, a tap anywhere on the paragraph's row acts on the paragraph, so a short
  /// paragraph is as easy to hit as a long one. Taps on a sentence link also reach `funnel`, which
  /// applies one touch once.
  @ViewBuilder
  func transcriptRowTap(
    isMarking: Bool, funnel: TranscriptTapFunnel, firstSentence: Int,
    onRowTap: @escaping (Int) -> Void
  ) -> some View {
    if isMarking {
      contentShape(Rectangle())
        .onTapGesture { funnel.row { onRowTap(firstSentence) } }
    } else {
      self
    }
  }

  /// A paragraph's VoiceOver actions for tapping a sentence: choose an ad's edges while marking,
  /// play from the paragraph otherwise.
  @ViewBuilder
  func transcriptTapActions(
    isMarking: Bool, paragraph: TranscriptParagraphs.Paragraph,
    onPlay: @escaping (Int) -> Void, onStart: @escaping (Int) -> Void,
    onEnd: @escaping (Int) -> Void
  ) -> some View {
    if isMarking {
      let last = paragraph.firstSentenceIndex + paragraph.sentences.count - 1
      accessibilityAction(named: Text(verbatim: TranscriptAdMarkingCopy.startAction)) {
        onStart(paragraph.firstSentenceIndex)
      }
      .accessibilityAction(named: Text(verbatim: TranscriptAdMarkingCopy.endAction)) {
        onEnd(last)
      }
    } else {
      accessibilityAction(named: "Play from Here") { onPlay(paragraph.firstSentenceIndex) }
    }
  }
}

/// Delivers one touch once. While marking, a touch on a sentence can reach both the sentence's
/// link and the row's tap gesture, in either order; both record here, and a flush on the next
/// main-queue turn applies the link's action if one arrived, otherwise the row's. Outside
/// marking a link applies at once, since there is no row gesture to duplicate it.
@MainActor
final class TranscriptTapFunnel {
  private var pendingLink: (() -> Void)?
  private var pendingRow: (() -> Void)?
  private var flushScheduled = false

  func link(_ sentence: Int, deferred: Bool, apply: @escaping (Int) -> Void) {
    guard deferred else {
      apply(sentence)
      return
    }
    pendingLink = { apply(sentence) }
    scheduleFlush()
  }

  func row(_ apply: @escaping () -> Void) {
    pendingRow = apply
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated { flush() }
    }
  }

  private func flush() {
    let action = pendingLink ?? pendingRow
    pendingLink = nil
    pendingRow = nil
    flushScheduled = false
    action?()
  }
}
