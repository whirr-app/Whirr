import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct ItemDetailDownloadBubbleView: View {
  let model: ItemDownloadModel
  let category: ItemMediaCategory
  let hasReadableEbook: Bool
  @State private var isConfirmingRemove = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // MARK: - Download bubble

  /// The trailing nav-bar download bubble: a plain `ToolbarItem`. iOS 26 gives every toolbar
  /// button Liquid Glass and the native morph transition on push/pop, so there is no custom glass
  /// surface to police against `GlassEffectPolicy`. Which branch renders, and what a tap does, is
  /// decided by
  /// `ItemDetailDownloadBubblePresentation.tapBehavior(for:status:formatStatus:category:hasReadableEbook:)`;
  /// this view only switches over that result.
  @ViewBuilder
  var body: some View {
    let kind = ItemDetailViewPresentation.controlKind(for: model.status)
    let formatOptions = ItemDetailDownloadBubblePresentation.downloadOptions(
      for: model.status, formatStatus: model.formatStatus, category: category, hasReadableEbook: hasReadableEbook)
    let icon = ItemDetailDownloadBubblePresentation.systemImage(for: kind)
    let progress = ItemDetailViewPresentation.progressFraction(for: model.status)
    let statusText = model.statusText

    switch ItemDetailDownloadBubblePresentation.tapBehavior(
      for: kind, status: model.status, formatStatus: model.formatStatus, category: category,
      hasReadableEbook: hasReadableEbook
    ) {
    case .direct:
      directDownloadBubble(kind: kind, icon: icon, statusText: statusText)

    case .menu:
      Menu {
        if formatOptions.isEmpty {
          Button(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: kind)) {
            Task {
              await Self.performPrimaryAction(
                for: kind, category: category, model: model)
            }
          }
          if let secondaryLabel = ItemDetailViewPresentation.secondaryActionLabel(for: kind) {
            Button(secondaryLabel, role: .destructive) {
              Task { await model.remove() }
            }
          }
        } else {
          ForEach(formatOptions, id: \.self) { option in
            Button(option.label) {
              Task { await model.requestDownload(format: option.format) }
            }
          }
          if let removeLabel = ItemDetailDownloadBubblePresentation.formatMenuRemoveLabel(
            for: kind, options: formatOptions
          ) {
            Button(
              removeLabel, role: .destructive
            ) {
              Task { await model.remove() }
            }
          }
        }
      } label: {
        bubbleIcon(systemImage: icon, progressFraction: progress, kind: kind)
      }
      .menuIndicator(.hidden)
      .disabled(!model.isActionable)
      .accessibilityIdentifier(ScreenAccessibilityID.itemDetailDownloadControl)
      .accessibilityLabel(statusText)
      .accessibilityHint(ItemDetailDownloadBubblePresentation.menuAccessibilityHint(for: kind))

    case .confirm:
      Button {
        isConfirmingRemove = true
      } label: {
        bubbleIcon(systemImage: icon, progressFraction: nil, kind: kind)
      }
      .disabled(!model.isActionable)
      .accessibilityIdentifier(ScreenAccessibilityID.itemDetailDownloadControl)
      .accessibilityLabel(statusText)
      .accessibilityHint(ItemDetailViewPresentation.primaryActionHint(for: kind))
      .confirmationDialog(
        "\(MediaActionCopy.removeDownload.title)?", isPresented: $isConfirmingRemove, titleVisibility: .visible
      ) {
        Button(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: kind), role: .destructive) {
          Task { await model.remove() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(ItemDetailViewPresentation.primaryActionHint(for: kind))
      }

    case .disabled:
      bubbleIcon(systemImage: icon, progressFraction: nil, kind: kind)
        .accessibilityIdentifier(ScreenAccessibilityID.itemDetailDownloadControl)
        .accessibilityLabel(statusText)
    }
  }

  /// The `.direct` branch (tap to download or resume) acts at once. Where
  /// `ItemDetailDownloadBubblePresentation.exposesSecondaryRemove`, "Remove" is a long-press menu
  /// entry and an accessibility action, so VoiceOver needn't long-press.
  @ViewBuilder
  private func directDownloadBubble(kind: DownloadControlKind, icon: String?, statusText: String) -> some View {
    let button =
      Button {
        Task {
          await Self.performPrimaryAction(
            for: kind, category: category, model: model)
        }
      } label: {
        bubbleIcon(systemImage: icon, progressFraction: nil, kind: kind)
      }
      .disabled(!model.isActionable)
      .accessibilityIdentifier(ScreenAccessibilityID.itemDetailDownloadControl)
      .accessibilityLabel(statusText)
      .accessibilityHint(ItemDetailViewPresentation.primaryActionHint(for: kind))

    if ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: kind),
      let secondaryLabel = ItemDetailViewPresentation.secondaryActionLabel(for: kind)
    {
      button
        .contextMenu {
          Button(secondaryLabel, role: .destructive) {
            Task { await model.remove() }
          }
        }
        .accessibilityAction(named: Text(secondaryLabel)) {
          Task { await model.remove() }
        }
    } else {
      button
    }
  }

  /// The bubble's icon-only content: a determinate ring and download glyph while a fraction is
  /// known (downloading), otherwise a plain glyph. The custom ring keeps the active state visible
  /// in the compact Liquid Glass toolbar, where the native accessory gauge can collapse into an
  /// empty track.
  ///
  /// Only the ring is sized (`DownloadProgressRing` has no intrinsic size); the plain glyph takes
  /// the bar's metrics, as a fixed 22pt box with `.imageScale(.medium)` draws it a step smaller.
  /// `kind` colours the glyph, not the screen's `.tint`: neutral unless the state needs the
  /// listener (`DownloadControlRole`).
  @ViewBuilder
  private func bubbleIcon(
    systemImage: String?, progressFraction: Double?, kind: DownloadControlKind
  ) -> some View {
    Group {
      if let progressFraction {
        DownloadProgressRing(progressFraction: progressFraction, systemImage: systemImage)
          .frame(width: 22, height: 22)
          .imageScale(.medium)
          .fixedSize()
      } else if let systemImage {
        Image(systemName: systemImage)
          .contentTransition(
            ItemDetailDownloadBubblePresentation.symbolMotion(reduceMotion: reduceMotion)
              .transition)
      }
    }
    .foregroundStyle(DownloadControlRole.tint(for: kind))
  }

  @MainActor
  private static func performPrimaryAction(
    for kind: DownloadControlKind, category: ItemMediaCategory, model: ItemDownloadModel
  ) async {
    switch kind {
    case .notDownloaded:
      await model.requestDownload(category: category)
    case .waitingForWiFi, .queued, .completed:
      await model.remove()
    case .downloading:
      await model.pause()
    case .paused, .pausedAuth, .interrupted, .failed:
      await model.resume()
    case .deleting:
      break
    }
  }
}
