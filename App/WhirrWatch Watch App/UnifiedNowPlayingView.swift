import PlayerCore
import SwiftUI
import WatchPlayback
import WatchProtocol

struct UnifiedNowPlayingView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchAudioEngine.self) private var audio
  @State private var moving = false

  private var backwardSeconds: Int { WatchDisplayFormatting.skipInterval(snapshot: companion.snapshot, forward: false) }
  private var forwardSeconds: Int { WatchDisplayFormatting.skipInterval(snapshot: companion.snapshot, forward: true) }
  private var accountsMatch: Bool {
    guard let stamp = try? model.account?.authenticatedStamp() else { return false }
    return stamp == companion.snapshot?.authenticatedAccountStamp
  }
  private var projection: WatchNowPlayingProjection {
    WatchNowPlayingProjection(
      .init(
        local: model.currentSelection.map {
          .init(
            selection: $0, title: audio.title, playing: audio.playing, wantsPlayback: model.playback.wantsPlayback,
            failure: audio.failure, lastListenedAt: model.playback.lastListened($0))
        },
        snapshot: companion.snapshot, snapshotIsStale: companion.snapshotIsStale,
        commandPending: companion.pendingCommandID != nil, busyHolder: model.busyHolder, moving: moving,
        accountsMatch: accountsMatch, phoneReachable: companion.phoneCanBeReached,
        localNativeCopies: model.readyEpisodeSelections))
  }
  private var localOwner: Bool { projection.isWatch }
  private var phoneItem: WatchCatalogueItem? { projection.phoneItem }
  /// The loaded title is a native-RSS episode. Its handoff to the phone is ABS-only, so the "On
  /// Watch" destination section has no Continue on iPhone to offer it.
  private var localIsNative: Bool {
    model.currentSelection.flatMap { WatchNativeSelection($0) } != nil
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @State private var showsAudioOptions = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if projection.hasSelection {
        playerPanel
      } else {
        ScrollView {
          WatchEmptyState(
            title: "Nothing playing",
            message: "Choose a title from your library.", systemImage: "headphones")
        }
      }
    }
    .ignoresSafeArea(.container, edges: .bottom)
    .background { playerBackdrop }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Audio options", systemImage: "airplay.audio") { showsAudioOptions = true }
          .labelStyle(.iconOnly)
          .disabled(projection.audioOptionsDisabled)
      }
    }
    .sheet(isPresented: $showsAudioOptions) {
      NavigationStack { audioOptions }
    }
  }

  private var playerPanel: some View {
    GeometryReader { geometry in
      VStack(spacing: 4) {
        if geometry.size.width >= 184 && dynamicTypeSize < .xxxLarge {
          GeometryReader { artworkSpace in
            playerArtwork(size: min(112, max(1, artworkSpace.size.height)))
              .frame(width: artworkSpace.size.width, height: artworkSpace.size.height)
          }
          playerTitle.lineLimit(1)
        } else {
          HStack(spacing: 8) {
            playerArtwork(size: 60)
            playerTitle.lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: .infinity)
        }
        NowPlayingProgress(
          localOwner: localOwner, phoneItem: phoneItem, phoneSnapshot: companion.snapshot,
          phoneSnapshotIsStale: companion.snapshotIsStale
        ).layoutPriority(1)
        transport.layoutPriority(1)
        WatchActionStatusView()
      }
      .padding(.horizontal, 6).padding(.bottom, 8)
    }
  }

  @ViewBuilder
  private var playerBackdrop: some View {
    if !isLuminanceReduced {
      if let selection = projection.selection {
        GeometryReader { geometry in
          WatchArtworkView(
            selection: selection,
            phoneCatalogueStamp: localOwner ? nil : companion.snapshot?.accountStamp, backdrop: true
          )
          .frame(width: geometry.size.width, height: geometry.size.height)
        }.ignoresSafeArea()
      }
    }
  }

  private var playerTitle: some View {
    Text(projection.title).font(.headline).accessibilityValue(projection.playbackStatus ?? "")
  }

  @ViewBuilder
  private func playerArtwork(size: CGFloat) -> some View {
    if let selection = projection.selection {
      let volumeOrigin: WatchVolumeControl.Origin = localOwner ? .watch : .phone
      WatchArtworkView(
        selection: selection, size: size,
        phoneCatalogueStamp: localOwner ? nil : companion.snapshot?.accountStamp
      )
      .overlay(alignment: .bottomTrailing) {
        WatchVolumeGlyph(origin: volumeOrigin, focused: !showsAudioOptions, side: size >= 80 ? 18 : 16)
          .padding(2)
      }
    }
  }

  private var transport: some View {
    HStack(spacing: 4) {
      Button {
        skip(by: -Double(backwardSeconds))
      } label: {
        Image(systemName: "gobackward.\(backwardSeconds)").font(.title3).frame(width: 44, height: 44)
          .glassEffect(.regular.interactive(), in: .circle)
      }.accessibilityLabel("Back \(backwardSeconds) seconds").disabled(projection.controlsDisabled)
      Button {
        togglePlayback()
      } label: {
        Group {
          if projection.loading {
            ProgressView()
          } else {
            Image(systemName: projection.playing ? "pause.fill" : "play.fill")
          }
        }
        .font(.title2).frame(width: 52, height: 52)
        .glassEffect(.regular.interactive(), in: .circle)
      }
      .accessibilityLabel(projection.playButtonLabel)
      .accessibilityValue(projection.loading ? "Loading" : "")
      .disabled(projection.startingActionsDisabled)
      Button {
        skip(by: Double(forwardSeconds))
      } label: {
        Image(systemName: "goforward.\(forwardSeconds)").font(.title3).frame(width: 44, height: 44)
          .glassEffect(.regular.interactive(), in: .circle)
      }.accessibilityLabel("Forward \(forwardSeconds) seconds").disabled(projection.controlsDisabled)
    }
    .buttonStyle(.plain)
  }

  private func togglePlayback() {
    switch projection.playIntent {
    case .pauseWatch: Task { await model.pause() }
    case .resumeWatch: Task { await model.resume() }
    case .phone(let action): if let item = phoneItem { send(item: item, action: action) }
    case .none: break
    }
  }

  private func skip(by seconds: Double) {
    if localOwner {
      model.skip(by: seconds)
    } else if let item = phoneItem {
      // The phone's live playhead can be ahead of the last catalogue publication.
      send(item: item, action: .skip, value: seconds)
    }
  }

  private var audioOptions: some View {
    List {
      Section { Text(projection.title).font(.headline) }
      if localOwner {
        localAudioOptions
      } else if let item = phoneItem, projection.offersPhoneOptions {
        phoneAudioOptions(item: item)
      }
      Section("Audio output") {
        Text(
          localOwner
            ? "Choose headphones in Watch Control Centre."
            : "Choose headphones or speakers on your iPhone."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      WatchActionStatusView()
    }
    .disabled(moving)
    .navigationTitle("Audio")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done", systemImage: "xmark") { showsAudioOptions = false }.labelStyle(.iconOnly)
      }
    }
  }

  @ViewBuilder
  private var localAudioOptions: some View {
    if !localIsNative {
      destinationSection(current: .watch, selection: model.currentSelection)
    }
    Section("Playback") {
      // The progress line above opens this too; the row keeps it discoverable, and it is the
      // only whole-timeline control a received episode has.
      if WatchSeekPosition.isSeekable(duration: audio.duration) {
        NavigationLink {
          WatchSeekView()
        } label: {
          Label("Seek", systemImage: "arrow.left.and.right").frame(minHeight: 44)
        }
      }
      NavigationLink {
        WatchPlaybackSpeedView(
          dismissAfterSelection: true, currentRate: audio.selectedRate,
          presets: companion.snapshot?.playbackRatePresets
        ) { rate in
          Task { await model.setRate(rate) }
        }
      } label: {
        speedLabel(rate: audio.selectedRate)
      }
      if !audio.chapters.chapters.isEmpty {
        NavigationLink {
          WatchChapterListView()
        } label: {
          Label("Chapters", systemImage: "list.bullet").frame(minHeight: 44)
        }
      }
    }.disabled(projection.busy)
  }

  @ViewBuilder
  private func phoneAudioOptions(item: WatchCatalogueItem) -> some View {
    destinationSection(current: .phone, selection: item.selection, item: item)
    // A dormant player publishes no rate, so the row would offer an empty, inert control.
    if !projection.canStartPhonePlayback {
      NavigationLink {
        WatchPlaybackSpeedView(
          dismissAfterSelection: true, currentRate: phoneRate, presets: companion.snapshot?.playbackRatePresets
        ) { rate in
          send(item: item, action: .setRate, value: rate)
        }
      } label: {
        speedLabel(rate: phoneRate)
      }.disabled(projection.controlsDisabled)
    }
  }

  private var phoneRate: Double? { projection.phoneRate }

  private func speedLabel(rate: Double?) -> some View {
    HStack {
      Label("Speed", systemImage: "speedometer")
      Spacer(minLength: 4)
      if let rate { Text("\(rate.formatted())×").monospacedDigit().foregroundStyle(.secondary) }
    }.frame(minHeight: 44)
  }

  @ViewBuilder
  private func destinationSection(
    current: WatchPlaybackDestination,
    selection: WatchSelection?,
    item: WatchCatalogueItem? = nil
  ) -> some View {
    Section {
      if current == .phone {
        let supported =
          item.map {
            WatchDestinationPreference.supports(
              .watch, selection: $0.selection, capabilities: $0.capabilities,
              hasLocalCopy: model.hasReadyEpisodeCopy($0.selection))
          } ?? false
        if supported {
          if model.account == nil {
            NavigationLink {
              WatchAccountView()
            } label: {
              Label("Set up Watch", systemImage: "applewatch").frame(minHeight: 44)
            }
          } else if accountsMatch, let selection, let item {
            Button {
              movePlayback(to: .watch, selection: selection)
            } label: {
              // The one way back to the Watch, from the phone's position even when a paused Watch title is
              // still loaded. An unreachable phone cannot be asked to pause, so this only starts the Watch.
              Label(projection.offersPlayOnWatch ? "Play on Watch" : "Move to Watch", systemImage: "applewatch")
                .frame(minHeight: 44)
            }.disabled(projection.moveToWatchDisabled)
            downloadAction(item: item)
          } else {
            NavigationLink {
              WatchAccountView()
            } label: {
              Label("Watch account", systemImage: "applewatch").frame(minHeight: 44)
            }
          }
        }
      } else if let selection {
        Button {
          movePlayback(to: .phone, selection: selection)
        } label: {
          Label("Move to iPhone", systemImage: "iphone").frame(minHeight: 44)
        }.disabled(projection.moveToPhoneDisabled)
        if !accountsMatch {
          Text("Open the same account on your iPhone to move playback.").font(.caption)
        }
      }
    } header: {
      Label(current == .phone ? "On iPhone" : "On Watch", systemImage: current == .phone ? "iphone" : "applewatch")
        .textCase(nil)
    }
  }

  /// Taking the phone's title out without the phone needs it on the Watch, and this sheet is the
  /// only place the phone's current title is reachable from Home.
  @ViewBuilder
  private func downloadAction(item: WatchCatalogueItem) -> some View {
    let stamp = try? model.account?.authenticatedStamp()
    if let group = model.downloadGroups.first(where: { $0.selection == item.selection && $0.accountStamp == stamp }) {
      let presentation = model.downloadPresentation(for: group)
      if presentation.canRetry {
        Button {
          Task {
            guard accountsMatch else { return }
            await model.retry(group: group)
          }
        } label: {
          Label("Retry download", systemImage: "arrow.clockwise").frame(minHeight: 44)
        }.disabled(projection.busy)
      } else {
        Label(presentation.status, systemImage: group.isReady ? "checkmark.circle.fill" : "arrow.down.circle")
          .font(.caption).foregroundStyle(group.isReady ? WatchVisualStyle.downloads : .secondary)
      }
    } else {
      Button {
        Task {
          guard accountsMatch else { return }
          await model.download(item.selection, title: item.title)
        }
      } label: {
        Label("Download to Watch", systemImage: "arrow.down.circle").frame(minHeight: 44)
      }.disabled(projection.busy)
    }
  }

  private func movePlayback(to destination: WatchPlaybackDestination, selection: WatchSelection) {
    let disabled = destination == .watch ? projection.moveToWatchDisabled : projection.moveToPhoneDisabled
    guard !moving, !disabled, accountsMatch,
      let stamp = try? model.account?.authenticatedStamp()
    else { return }
    moving = true
    Task {
      defer { moving = false }
      guard accountsMatch, (try? model.account?.authenticatedStamp()) == stamp,
        selection == (localOwner ? model.currentSelection : phoneItem?.selection)
      else { return }
      if destination == .watch {
        guard !localOwner, let item = phoneItem,
          WatchDestinationPreference.supports(
            .watch, selection: item.selection, capabilities: item.capabilities,
            hasLocalCopy: model.hasReadyEpisodeCopy(item.selection))
        else { return }
        await model.play(selection)
      } else {
        guard localOwner else { return }
        await model.continueOnPhone()
      }
    }
  }

  private func send(item: WatchCatalogueItem, action: WatchCommandAction, value: Double? = nil) {
    // Only the play button reaches a dormant phone player; every other action needs live transport.
    let starting = action == .play
    guard !(starting ? projection.startingActionsDisabled : projection.controlsDisabled) else { return }
    let stamp = companion.snapshot?.accountStamp
    Task {
      guard stamp != nil, stamp == companion.snapshot?.accountStamp, !localOwner,
        !(starting ? projection.startingActionsDisabled : projection.controlsDisabled),
        phoneItem?.selection == item.selection
      else { return }
      _ = await companion.send(selection: item.selection, action: action, value: value)
    }
  }
}

/// The progress line. It alone reads the engine's position, so the once-a-second sample redraws
/// this view and not the whole player. A playing phone's position arrives only every 15 s, so
/// between publications the line runs the phone's clock forward itself, once a second in step
/// with the publication, as the system's Now Playing does.
private struct NowPlayingProgress: View {
  @Environment(WatchAudioEngine.self) private var audio
  let localOwner: Bool
  let phoneItem: WatchCatalogueItem?
  let phoneSnapshot: WatchCatalogueSnapshot?
  let phoneSnapshotIsStale: Bool

  var body: some View {
    if !localOwner, let phoneItem, let phoneSnapshot,
      WatchNowPlayingProjection.phoneState(phoneSnapshot, isStale: phoneSnapshotIsStale) == .playing
    {
      TimelineView(.periodic(from: phoneSnapshot.generatedAt, by: 1)) { context in
        line(
          position: WatchNowPlayingProjection.estimatedPhonePosition(
            of: phoneItem, snapshot: phoneSnapshot, isStale: phoneSnapshotIsStale, at: context.date))
      }
    } else {
      let position = localOwner ? audio.position : phoneItem?.progressSeconds ?? 0
      if localOwner, WatchSeekPosition.isSeekable(duration: audio.duration) {
        NavigationLink {
          WatchSeekView()
        } label: {
          line(position: position)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens seeking")
      } else {
        line(position: position)
      }
    }
  }

  private func line(position: Double) -> some View {
    let chapter = localOwner ? audio.currentChapter : nil
    let chapterStart = localOwner ? chapter?.start : phoneItem?.chapterStartSeconds
    let chapterEnd = localOwner ? chapter?.end : phoneItem?.chapterEndSeconds
    let scope = WatchDisplayFormatting.playbackProgress(
      position: position,
      duration: localOwner ? audio.duration : phoneItem?.durationSeconds,
      chapterStart: chapterStart, chapterEnd: chapterEnd)
    let elapsed = scope.elapsed
    let duration = scope.duration ?? 0
    let chapterTitle = scope.isChapter ? (localOwner ? chapter?.title : phoneItem?.chapterTitle) : nil
    return VStack(spacing: 4) {
      if duration.isFinite && duration > 0 {
        GeometryReader { geometry in
          Capsule().fill(.white.opacity(0.2))
            .overlay(alignment: .leading) {
              Capsule().fill(.white)
                .frame(width: geometry.size.width * min(elapsed / duration, 1))
            }
        }.frame(height: 3)
          .accessibilityLabel(scope.isChapter ? "Chapter progress" : "Playback progress")
          .accessibilityValue("\(Int(min(elapsed / duration, 1) * 100)) percent")
      }
      HStack {
        Text(WatchDisplayFormatting.playerClock(elapsed))
          .accessibilityLabel(
            "\(WatchDisplayFormatting.playerClock(elapsed)) elapsed\(scope.isChapter ? " in chapter" : "")")
        Spacer(minLength: 2)
        if let chapterTitle {
          Text(ChapterTitleFormatting.compact(chapterTitle))
            .accessibilityLabel(chapterTitle)
          Spacer(minLength: 2)
        }
        if duration.isFinite && duration > 0 {
          Text("−\(WatchDisplayFormatting.playerClock(max(0, duration - elapsed)))")
            .accessibilityLabel(
              "\(WatchDisplayFormatting.remaining(duration - elapsed))\(scope.isChapter ? " in chapter" : "")")
        }
      }.font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
    }
  }
}
