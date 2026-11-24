import SwiftUI
import WatchPlayback
import WatchProtocol

/// The native-RSS copies the iPhone sent, under On My Watch. A ready copy opens its detail page; one
/// still arriving and one the Watch had no room for say so. An empty section draws nothing, so the
/// screen's own empty state still depends on the whole screen.
struct WatchReceivedEpisodesSection: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @State private var removing: WatchNativeSelection?

  private var rows: [WatchNativeEpisodeRow] {
    WatchNativeEpisodeRows.make(entries: model.receivedEpisodes, listens: model.nativeListens)
  }

  private var watchStamp: WatchAccountStamp? { try? model.account?.authenticatedStamp() }

  private var confirmingRemoval: Binding<Bool> {
    Binding(
      get: { removing != nil },
      set: { if !$0 { removing = nil } })
  }

  var body: some View {
    if !rows.isEmpty {
      Section("Podcasts") {
        ForEach(rows) { row in
          switch row.state {
          case .ready:
            NavigationLink {
              WatchSelectionDetailView(
                selection: row.selection, title: row.title, subtitle: subtitle(row),
                capabilities: .init(phonePlayable: true, watchPlayable: false),
                accountStamp: watchStamp, phoneCatalogueStamp: companion.snapshot?.accountStamp)
            } label: {
              label(row)
            }
            .accessibilityLabel(row.spokenLabel)
            .swipeActions(edge: .trailing) {
              Button(role: .destructive) {
                removing = row.entry.selection
              } label: {
                Label("Remove from Watch", systemImage: "trash")
              }
            }
          case .waitingToDownload, .downloading, .waitingForNetwork, .failed, .declined:
            label(row)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(row.spokenLabel)
          }
        }
      }
      .confirmationDialog(
        "Remove this episode from your Watch?", isPresented: confirmingRemoval, titleVisibility: .visible
      ) {
        Button("Remove from Watch", role: .destructive) {
          guard let selection = removing else { return }
          removing = nil
          Task { await model.removeEpisodeCopy(selection.selection) }
        }
        Button("Cancel", role: .cancel) { removing = nil }
      }
    }
  }

  private func subtitle(_ row: WatchNativeEpisodeRow) -> String {
    WatchDisplayFormatting.metadata([row.showTitle, row.status])
  }

  private func label(_ row: WatchNativeEpisodeRow) -> some View {
    HStack(spacing: 8) {
      WatchArtworkView(selection: row.selection, accountStamp: watchStamp)
      VStack(alignment: .leading, spacing: 4) {
        Text(row.title).font(.headline).lineLimit(2)
        Text(row.showTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        status(row)
      }
    }.frame(minHeight: 48)
  }

  /// The download state as the Audiobookshelf download rows draw it: the text on its own line, a
  /// mini spinner ahead of it while no fraction is known, and a full-width bar under it once one is.
  @ViewBuilder
  private func status(_ row: WatchNativeEpisodeRow) -> some View {
    if !row.status.isEmpty {
      HStack(spacing: 4) {
        if row.progress == .indeterminate {
          ProgressView().controlSize(.mini).accessibilityHidden(true)
        }
        Text(row.status).font(.caption2).lineLimit(1)
          .foregroundStyle(row.isProblem ? Color.orange : Color.secondary)
      }
    }
    if case .determinate(let value) = row.progress {
      ProgressView(value: value).progressViewStyle(.linear).tint(WatchVisualStyle.downloads)
        .accessibilityHidden(true)
    }
  }
}

/// An in-progress copy in Continue. It mirrors `WatchSelectionRow` and adds where it is, because a
/// native episode plays here and nowhere else.
struct WatchNativeContinueRow: View {
  @Environment(WatchCompanionStore.self) private var companion
  let item: WatchNativeContinueItem
  let accountStamp: WatchAccountStamp?

  private var subtitle: String {
    let left = max(0, item.durationSeconds - item.progressSeconds)
    return WatchDisplayFormatting.metadata([
      item.showTitle, "\(WatchDisplayFormatting.duration(left)) left",
    ])
  }

  var body: some View {
    NavigationLink {
      WatchSelectionDetailView(
        selection: item.selection, title: item.title, subtitle: subtitle,
        capabilities: .init(phonePlayable: true, watchPlayable: false),
        accountStamp: accountStamp, phoneCatalogueStamp: companion.snapshot?.accountStamp)
    } label: {
      HStack(spacing: 8) {
        WatchArtworkView(
          selection: item.selection, accountStamp: accountStamp,
          phoneCatalogueStamp: companion.snapshot?.accountStamp)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title).font(.headline).lineLimit(2)
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }.frame(minHeight: 48)
    }
    .accessibilityLabel(WatchDisplayFormatting.metadata([item.title, item.showTitle, "On Watch", subtitle]))
  }
}

/// A Followed on iPhone episode the Watch holds a copy of. The row keeps the phone's metadata and
/// gains a Watch glyph; its detail page plays the copy locally. Every other row is unchanged.
struct WatchFollowedEpisodeRow: View {
  @Environment(WatchLibraryModel.self) private var model
  let presentation: WatchPodcastEpisodePresentation

  private var playable: Bool {
    presentation.capabilities.phonePlayable || presentation.capabilities.watchPlayable
  }

  var body: some View {
    if model.hasReadyEpisodeCopy(presentation.selection), playable {
      NavigationLink {
        WatchSelectionDetailView(
          selection: presentation.selection, title: presentation.title, subtitle: presentation.metadata,
          capabilities: presentation.capabilities, accountStamp: presentation.accountStamp,
          phoneCatalogueStamp: presentation.phoneCatalogueStamp)
      } label: {
        HStack(spacing: 8) {
          WatchArtworkView(
            selection: presentation.selection, accountStamp: presentation.accountStamp,
            phoneCatalogueStamp: presentation.phoneCatalogueStamp)
          VStack(alignment: .leading, spacing: 3) {
            Text(presentation.title).font(.headline).lineLimit(2)
            Label(presentation.metadata, systemImage: "applewatch")
              .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              .labelStyle(WatchOnWatchGlyphStyle())
          }
        }.frame(minHeight: 48)
      }
      .accessibilityLabel(
        WatchDisplayFormatting.metadata([presentation.title, "On Watch", presentation.metadata]))
    } else {
      WatchPodcastEpisodeRow(presentation: presentation)
    }
  }
}

/// Keeps the glyph ahead of the text as the small Watch mark, and out of the spoken label: the row
/// says "On Watch" itself.
private struct WatchOnWatchGlyphStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
        .font(.caption2)
        .foregroundStyle(WatchVisualStyle.downloads)
        .accessibilityHidden(true)
      configuration.title
    }
  }
}
