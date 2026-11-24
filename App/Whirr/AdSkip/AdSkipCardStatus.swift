import AppModel
import Observation
import SwiftUI

/// What the episode card says about ad skipping before playback. Shorter than the player's
/// sentences for the same waits, because it shares a row with the "Show notes" heading.
enum AdSkipCardStatusPresentation {
  struct Content: Hashable {
    /// Shown when it fits beside the heading, and always what VoiceOver reads.
    let full: String
    /// Shown when the full copy does not fit.
    let short: String
    /// Shown with either copy, and alone when neither fits.
    let systemImage: String
    /// The symbol moves while the episode is being checked, as the tiles' glyph does.
    var animatesSymbol = false
  }

  /// Nil when there is nothing to say, including a held analysis whose reason has already gone:
  /// the coordinator will be told in a moment, and a stale line would be wrong.
  nonisolated static func content(
    for status: AdSkipEpisodeStatus, pauseReason: AdSkipPauseReason?
  ) -> Content? {
    switch status {
    case .none:
      return nil
    case .queued:
      return Content(full: "Ad check queued", short: "Queued", systemImage: "waveform")
    case .checking:
      return Content(
        full: "Checking for ads", short: "Checking", systemImage: "waveform", animatesSymbol: true)
    case .waiting(.speechModel):
      return Content(
        full: "Ad check waiting for speech model", short: "Waiting", systemImage: "arrow.down.circle")
    case .waiting(.conditions):
      guard let pauseReason else { return nil }
      let copy = AdSkipWaitPresentation.card(pauseReason)
      return Content(full: copy.full, short: copy.short, systemImage: copy.systemImage)
    case .ready(let breaks):
      guard breaks.count > 0 else {
        return Content(full: "No ads found", short: "No ads", systemImage: "checkmark")
      }
      let count = breaks.count == 1 ? "1 ad break" : "\(breaks.count) ad breaks"
      return Content(full: "Skips \(count)", short: count, systemImage: "forward.end")
    case .failed:
      return Content(
        full: "Couldn't check for ads", short: "Not checked", systemImage: "exclamationmark.triangle")
    }
  }
}

/// One card's ad-skip status: asked again on every change the coordinator signals, with the
/// reason analysis waits followed alongside.
@MainActor
@Observable
final class AdSkipCardStatusModel {
  /// Where the status comes from. Nil stands for no coordinator, which is the case while the
  /// database cannot open: nothing is analysed then, so there is nothing to say.
  struct Source {
    var status: @Sendable (_ itemID: String, _ episodeID: String) async -> AdSkipEpisodeStatus
    var changes: @Sendable () -> AsyncStream<Void>
    var pauseReasons: @MainActor () -> AsyncStream<AdSkipPauseReason?>

    static var live: Source? {
      guard let coordinator = AdSkipComposition.coordinator else { return nil }
      return Source(
        status: { await coordinator.episodeStatus(itemID: $0, episodeID: $1) },
        changes: { coordinator.episodeStatusChanges() },
        pauseReasons: { AdSkipAnalysisConditions.pauseReasonChanges() })
    }
  }

  private(set) var content: AdSkipCardStatusPresentation.Content?
  /// The skips the player will make from this episode's ranges, or nil until analysis is ready.
  /// Read by the progress lines alone, which leave the time ahead of the playhead out of the
  /// card's remainder.
  private(set) var breaks: AdSkipBreaks?

  private let itemID: String
  private let episodeID: String
  private let source: Source?
  @ObservationIgnored private var status = AdSkipEpisodeStatus.none
  @ObservationIgnored private var pauseReason: AdSkipPauseReason?

  init(itemID: String, episodeID: String, source: Source?) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.source = source
  }

  /// Follows the status until cancelled. The line runs it from its own task, so it lasts exactly
  /// as long as the line is on screen.
  func follow() async {
    guard let source else { return }
    // Opened before the first read, so a change during that read is not missed.
    let changes = source.changes()
    let reasons = source.pauseReasons()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [weak self] in
        for await reason in reasons {
          await self?.note(pauseReason: reason)
        }
      }
      group.addTask { [weak self] in
        await self?.reload()
        for await _ in changes {
          await self?.reload()
        }
      }
    }
  }

  private func reload() async {
    guard let source else { return }
    status = await source.status(itemID, episodeID)
    refresh()
  }

  private func note(pauseReason reason: AdSkipPauseReason?) {
    pauseReason = reason
    refresh()
  }

  private func refresh() {
    let next = AdSkipCardStatusPresentation.content(for: status, pauseReason: pauseReason)
    if content != next { content = next }
    let nextBreaks: AdSkipBreaks? =
      if case .ready(let breaks) = status { breaks } else { nil }
    if breaks != nextBreaks { breaks = nextBreaks }
  }
}

/// The card's status line. The model is read only in the leaf views it is handed to: this line
/// reads `content`, and the progress lines read `breaks`, so a status change redraws those and
/// not the card around them. Neither reads the playhead.
struct AdSkipCardStatusLine: View {
  let model: AdSkipCardStatusModel
  let secondaryInk: AnyShapeStyle

  var body: some View {
    AdSkipCardStatusText(content: model.content, secondaryInk: secondaryInk)
      .task { await model.follow() }
  }
}

/// One line of status that can never change the height or wrap: the slot is an empty line of the
/// heading's font, as wide as the row allows, and the copy is drawn over it. Whatever is drawn,
/// the layout sees only the empty line.
struct AdSkipCardStatusText: View {
  let content: AdSkipCardStatusPresentation.Content?
  /// The card's ink, which depends on whether it sits on glass.
  let secondaryInk: AnyShapeStyle

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Text(verbatim: " ")
      .font(.footnote)
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
      .overlay(alignment: .trailing) {
        ZStack(alignment: .trailing) {
          if let content {
            forms(content)
              .id(content)
              .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .default, value: content)
      }
  }

  /// The first form that fits beside the heading: the full copy, the short copy, the symbol.
  private func forms(_ content: AdSkipCardStatusPresentation.Content) -> some View {
    ViewThatFits(in: .horizontal) {
      form(content, text: content.full)
      form(content, text: content.short)
      form(content, text: nil)
    }
    .font(.footnote)
    .foregroundStyle(secondaryInk)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(content.full)
  }

  private func form(_ content: AdSkipCardStatusPresentation.Content, text: String?) -> some View {
    HStack(spacing: 4) {
      Image(systemName: content.systemImage)
        .imageScale(.small)
        .symbolEffect(
          .variableColor.iterative, options: .repeating,
          isActive: reduceMotion == false && content.animatesSymbol)
      if let text {
        Text(text)
          .lineLimit(1)
      }
    }
    // Without it `ViewThatFits` would truncate a form to fit, not reject it.
    .fixedSize()
  }
}
