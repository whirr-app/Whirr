import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchHomeView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchAudioEngine.self) private var audio
  @Environment(WatchPlayerPresentation.self) private var presentation
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced

  var body: some View {
    List {
      if model.currentSelection != nil || companion.currentItem != nil { currentPlayback }
      Section {
        NavigationLink {
          WatchAudiobooksView(client: model.browseClient)
        } label: {
          WatchCategoryLabel(
            title: "Audiobooks", systemImage: "books.vertical.fill", color: WatchVisualStyle.audiobooks)
        }.frame(minHeight: 44)
        NavigationLink {
          WatchPodcastsView(client: model.browseClient)
        } label: {
          WatchCategoryLabel(title: "Podcasts", systemImage: "mic.fill", color: WatchVisualStyle.podcasts)
        }.frame(minHeight: 44)
        NavigationLink {
          WatchDownloadsView()
        } label: {
          WatchCategoryLabel(title: "On My Watch", systemImage: "applewatch", color: WatchVisualStyle.downloads)
        }.frame(minHeight: 44)
      }
      continueListening
      Section {
        NavigationLink {
          WatchAccountView()
        } label: {
          WatchCategoryLabel(title: "Settings", systemImage: "gearshape.fill", color: .gray)
        }
      }
      WatchConnectionStatusView()
    }
    .task { await model.refreshReceivedEpisodes() }
  }

  @ViewBuilder private var currentPlayback: some View {
    if let selection = model.currentSelection {
      playbackCard(
        selection: selection, title: audio.title,
        status: audio.playing ? "Playing on Watch" : "Paused on Watch", isPlaying: audio.playing)
    } else if let item = companion.currentItem {
      playbackCard(
        selection: item.selection, title: item.title,
        status: phonePlaybackStatus,
        isPlaying: !companion.snapshotIsStale && companion.snapshot?.playbackState == .playing,
        phoneCatalogueStamp: companion.snapshot?.accountStamp)
    }
  }

  private func playbackCard(
    selection: WatchSelection, title: String, status: String?, isPlaying: Bool,
    phoneCatalogueStamp: WatchAccountStamp? = nil
  ) -> some View {
    Button {
      presentation.isPresented = true
    } label: {
      HStack(spacing: 8) {
        WatchArtworkView(selection: selection, size: 44, phoneCatalogueStamp: phoneCatalogueStamp)
          .overlay(alignment: .bottomTrailing) {
            if isPlaying {
              Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(WatchVisualStyle.primaryFill, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .offset(x: 3, y: 3).accessibilityHidden(true)
            }
          }
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.subheadline.weight(.semibold)).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          if let status { Text(status).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.vertical, 5)
    }
    .listRowBackground(
      GeometryReader { geometry in
        ZStack {
          WatchVisualStyle.rowSurface
          if !reduceTransparency && !isLuminanceReduced {
            WatchArtworkView(
              selection: selection, phoneCatalogueStamp: phoneCatalogueStamp,
              backdrop: true
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
              LinearGradient(
                colors: [.clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            }
          }
        }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    )
    .accessibilityLabel(WatchDisplayFormatting.metadata([title, status, "Now Playing"]))
  }

  private var phonePlaybackStatus: String? {
    WatchDisplayFormatting.phonePlaybackStatus(
      companion.snapshot?.playbackState,
      isStale: companion.snapshotIsStale)
  }

  @ViewBuilder private var continueListening: some View {
    let projection = model.homeProjection(scope: .home)
    // The current title is left out of the preview, so it alone must still lead to See All.
    if !projection.isEmpty || !model.homeProjection(scope: .continueListening(audiobooksOnly: false)).isEmpty {
      Section("Continue Listening") {
        ForEach(projection.phone) { item in
          WatchPhoneItemRow(item: item)
        }
        // Account changes never merge equal item IDs belonging to different accounts.
        if projection.showsWatchSection {
          ForEach(projection.watch) { item in
            WatchSelectionRow(
              selection: item.selection, title: model.continueTitles[item.selection] ?? "Resume listening",
              subtitle: nil, accountStamp: projection.watchAccountStamp)
          }
          ForEach(projection.native) { item in
            WatchNativeContinueRow(item: item, accountStamp: projection.watchAccountStamp)
          }
        }
        NavigationLink("See All") { WatchContinueView() }.frame(minHeight: 44)
      }
    }
  }
}
