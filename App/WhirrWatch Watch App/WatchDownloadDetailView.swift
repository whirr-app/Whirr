import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchDownloadDetailView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchPlayerPresentation.self) private var player
  let groupID: String
  @State private var showsActions = false
  @State private var working = false
  @State private var isVisible = false

  private var group: WatchDownloadGroup? { model.downloadGroups.first { $0.id == groupID } }

  private func loadedState(_ group: WatchDownloadGroup) -> WatchLoadedItemState {
    guard group.accountStamp == (try? model.account?.authenticatedStamp()) else { return .notLoaded }
    return WatchNavigationPolicy.loadedState(
      of: group.selection, current: model.currentSelection, wantsPlayback: model.playback.wantsPlayback)
  }

  var body: some View {
    ScrollView {
      if let group {
        let presentation = model.downloadPresentation(for: group)
        VStack(alignment: .leading, spacing: 12) {
          header(group, presentation)
          actionCluster(for: group, presentation: presentation)
          WatchActionStatusView(observesPhoneCommands: false)
        }.disabled(working || model.busy)
          .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
      } else {
        WatchEmptyState(
          title: "Download removed", message: "Find more titles in your library.",
          systemImage: "arrow.down.circle", color: WatchVisualStyle.downloads)
      }
    }.navigationTitle("Listen").watchPlayerToolbar()
      .sheet(isPresented: $showsActions) { removeSheet }
      .onAppear { isVisible = true }
      .onDisappear { isVisible = false }
  }

  @ViewBuilder
  private func header(
    _ group: WatchDownloadGroup, _ presentation: WatchDownloadRowPresentation
  ) -> some View {
    HStack(spacing: 8) {
      WatchArtworkView(selection: group.selection, size: 48, accountStamp: group.accountStamp)
      Text(presentation.title).font(.headline).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
    }
    if !group.isReady {
      VStack(alignment: .leading, spacing: 6) {
        Text(presentation.status).font(.caption).foregroundStyle(.secondary)
        if let progress = group.progress {
          ProgressView(value: progress).progressViewStyle(.linear).tint(WatchVisualStyle.downloads)
            .accessibilityLabel("Download progress")
        }
      }
    }
  }

  private func actionCluster(
    for group: WatchDownloadGroup, presentation: WatchDownloadRowPresentation
  ) -> some View {
    WatchItemActionLayout(showsMore: true) { compact in
      action(for: group, presentation: presentation, compact: compact)
    } more: {
      showsActions = true
    }
  }

  @ViewBuilder
  private func action(
    for group: WatchDownloadGroup, presentation: WatchDownloadRowPresentation, compact: Bool
  ) -> some View {
    if loadedState(group) == .active {
      Button {
        player.isPresented = true
      } label: {
        WatchPrimaryActionLabel(
          title: "Now Playing", compactTitle: "Playing", systemImage: "waveform", compact: compact)
      }.buttonStyle(.plain)
    } else if loadedState(group) == .paused {
      resumeButton(group, compact: compact)
    } else if group.isReady {
      playButton(group, compact: compact)
    } else if presentation.canRetry {
      retryButton(group, compact: compact)
    } else {
      Spacer(minLength: 0)
    }
  }

  private func resumeButton(_ group: WatchDownloadGroup, compact: Bool) -> some View {
    Button {
      working = true
      Task {
        defer { working = false }
        guard loadedState(group) == .paused else { return }
        await model.resume()
        if isVisible, model.currentSelection == group.selection { player.isPresented = true }
      }
    } label: {
      WatchPrimaryActionLabel(
        title: "Resume on Watch", compactTitle: "Resume", systemImage: "play.fill", compact: compact)
    }.buttonStyle(.plain)
  }

  private func playButton(_ group: WatchDownloadGroup, compact: Bool) -> some View {
    Button {
      working = true
      Task {
        defer { working = false }
        await model.play(group: group)
        if isVisible, group.accountStamp == (try? model.account?.authenticatedStamp()),
          model.currentSelection == group.selection, model.audio.playing
        {
          player.isPresented = true
        }
      }
    } label: {
      WatchPrimaryActionLabel(
        title: "Play on Watch", compactTitle: "Watch", systemImage: "play.fill", compact: compact)
    }.buttonStyle(.plain)
  }

  private func retryButton(_ group: WatchDownloadGroup, compact: Bool) -> some View {
    Button {
      working = true
      Task {
        defer { working = false }
        await model.retry(group: group)
      }
    } label: {
      WatchPrimaryActionLabel(
        title: "Retry download", compactTitle: "Retry", systemImage: "arrow.clockwise", compact: compact)
    }.buttonStyle(.plain)
  }

  @ViewBuilder
  private var removeSheet: some View {
    NavigationStack {
      List {
        if let group {
          Button(role: .destructive) {
            showsActions = false
            working = true
            Task {
              defer { working = false }
              await model.delete(group: group)
            }
          } label: {
            WatchCenteredActionLabel(title: "Remove from Watch", systemImage: "trash")
          }.frame(minHeight: 44).disabled(working || model.busy)
        }
      }.navigationTitle("More")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done", systemImage: "xmark") { showsActions = false }.labelStyle(.iconOnly)
          }
        }
    }
  }

}
