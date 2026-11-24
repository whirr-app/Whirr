import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchSelectionDetailView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchPlayerPresentation.self) private var presentation
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  let selection: WatchSelection
  let title: String
  let subtitle: String?
  let capabilities: WatchSelectionCapabilities
  let accountStamp: WatchAccountStamp?
  let phoneCatalogueStamp: WatchAccountStamp?
  @State private var working = false
  @State private var showsActions = false
  @State private var pendingPhoneRequest: (stamp: WatchAccountStamp, snapshotDate: Date)?
  @State private var isVisible = false
  @State private var startingDownload = false
  @State private var confirmsRemoval = false

  /// A native-feed episode plays from a copy the phone sent; the wire never claims it does.
  private var nativeSelection: WatchNativeSelection? { WatchNativeSelection(selection) }

  private var hasLocalCopy: Bool { model.hasReadyEpisodeCopy(selection) }

  private var phoneAvailable: Bool {
    guard capabilities.phonePlayable else { return false }
    if let phoneCatalogueStamp { return companion.snapshot?.accountStamp == phoneCatalogueStamp }
    return accountStamp != nil && companion.snapshot?.authenticatedAccountStamp == accountStamp
  }

  private var watchSupported: Bool {
    WatchDestinationPreference.supports(
      .watch, selection: selection, capabilities: capabilities, hasLocalCopy: hasLocalCopy)
  }

  private var watchAccountMatches: Bool {
    accountStamp != nil && (try? model.account?.authenticatedStamp()) == accountStamp
  }

  private var primaryDestination: WatchPlaybackDestination? {
    // A title loaded on the Watch prefers the Watch, and so does a native episode with a copy: the
    // copy is the only place it can play from here. Otherwise the phone, which needs no Watch account.
    let preferred: WatchPlaybackDestination =
      model.currentSelection != nil || (nativeSelection != nil && hasLocalCopy) ? .watch : .phone
    return WatchNavigationPolicy.itemDestination(
      selection: selection, capabilities: capabilities, preferred: preferred,
      phoneAvailable: phoneAvailable, watchAvailable: watchAccountMatches,
      hasLocalCopy: hasLocalCopy)
  }

  private var hasSecondaryActions: Bool {
    WatchNavigationPolicy.itemOffersMoreActions(
      watchSupported: watchSupported, watchAccountMatches: watchAccountMatches, primary: primaryDestination,
      phonePlayable: capabilities.phonePlayable)
  }

  private var loadedState: WatchLoadedItemState {
    guard watchAccountMatches else { return .notLoaded }
    return WatchNavigationPolicy.loadedState(
      of: selection, current: model.currentSelection, wantsPlayback: model.playback.wantsPlayback)
  }

  private var busy: Bool { working || model.busy || companion.pendingCommandID != nil }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 8) {
            WatchArtworkView(
              selection: selection, size: geometry.size.width >= 184 && dynamicTypeSize < .xxxLarge ? 64 : 48,
              accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp)
            VStack(alignment: .leading, spacing: 4) {
              Text(title).font(.headline.weight(.semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
              if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          WatchItemActionLayout(showsMore: hasSecondaryActions) { compact in
            primaryAction(compact: compact)
          } more: {
            showsActions = true
          }.disabled(busy)
          downloadStatus
          WatchActionStatusView()
        }.padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 8)
      }
    }
    .background {
      if !reduceTransparency && !isLuminanceReduced {
        GeometryReader { geometry in
          WatchArtworkView(
            selection: selection, accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp,
            backdrop: true
          )
          .frame(width: geometry.size.width, height: geometry.size.height)
          .mask {
            LinearGradient(
              stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.85)],
              startPoint: .top, endPoint: .bottom)
          }
        }.ignoresSafeArea().allowsHitTesting(false)
      }
    }
    .navigationTitle("Listen").watchPlayerToolbar()
    .sheet(isPresented: $showsActions) {
      NavigationStack { secondaryActions }
    }
    .onChange(of: companion.snapshot) { _, _ in presentConfirmedPhonePlayback() }
    .onAppear { isVisible = true }
    .onDisappear {
      isVisible = false
      pendingPhoneRequest = nil
    }
  }

  @ViewBuilder
  private func primaryAction(compact: Bool) -> some View {
    if let destination = primaryDestination {
      if destination == .watch && !watchAccountMatches {
        NavigationLink {
          WatchAccountView()
        } label: {
          WatchPrimaryActionLabel(
            title: "Set up Watch", compactTitle: "Set up", systemImage: "applewatch", compact: compact)
        }.buttonStyle(.plain)
      } else if destination == .watch && loadedState == .active {
        Button {
          presentation.isPresented = true
        } label: {
          WatchPrimaryActionLabel(
            title: "Now Playing", compactTitle: "Playing", systemImage: "waveform", compact: compact)
        }.buttonStyle(.plain)
      } else if destination == .watch && loadedState == .paused {
        Button {
          resumeOnWatch()
        } label: {
          WatchPrimaryActionLabel(
            title: "Resume on Watch", compactTitle: "Resume", systemImage: "play.fill", compact: compact)
        }.buttonStyle(.plain)
      } else {
        Button {
          play(on: destination)
        } label: {
          WatchPrimaryActionLabel(
            title: destination == .watch ? "Play on Watch" : "Play on iPhone",
            compactTitle: destination == .watch ? "Watch" : "iPhone", systemImage: "play.fill", compact: compact)
        }.buttonStyle(.plain)
      }
    }
  }

  /// The download for this title on the signed-in Watch account, if one exists.
  private var downloadGroup: WatchDownloadGroup? {
    guard watchAccountMatches else { return nil }
    return model.downloadGroups.first { $0.selection == selection && $0.accountStamp == accountStamp }
  }

  /// A download tap dismisses the sheet, so its result has to show here: without this the only
  /// evidence a download started was a row under On My Watch.
  @ViewBuilder
  private var downloadStatus: some View {
    if nativeSelection != nil {
      if !hasLocalCopy {
        Label(WatchPlaybackNotice.nativeFeed.text, systemImage: "applewatch")
          .font(.caption).foregroundStyle(.secondary)
      }
    } else if let group = downloadGroup {
      VStack(alignment: .leading, spacing: 6) {
        Label(
          model.downloadPresentation(for: group).status,
          systemImage: group.isReady ? "checkmark.circle.fill" : "arrow.down.circle"
        )
        .font(.caption).foregroundStyle(group.isReady ? WatchVisualStyle.downloads : .secondary)
        if let progress = group.progress, !group.isReady {
          ProgressView(value: progress).progressViewStyle(.linear).tint(WatchVisualStyle.downloads)
            .accessibilityLabel("Download progress")
        }
      }
    } else if startingDownload {
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Starting download").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var secondaryActions: some View {
    List {
      playOnPhoneAction
      if nativeSelection != nil {
        nativeCopyActions
      } else if watchSupported {
        watchActions
      }
    }
    .disabled(busy).navigationTitle("More")
    .confirmationDialog(
      "Remove this episode from your Watch?", isPresented: $confirmsRemoval, titleVisibility: .visible
    ) {
      Button("Remove from Watch", role: .destructive) {
        showsActions = false
        working = true
        Task {
          defer { working = false }
          await model.removeEpisodeCopy(selection)
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done", systemImage: "xmark") { showsActions = false }.labelStyle(.iconOnly)
      }
    }
  }

  @ViewBuilder
  private var playOnPhoneAction: some View {
    if primaryDestination == .watch && capabilities.phonePlayable {
      Button {
        play(on: .phone)
      } label: {
        WatchCenteredActionLabel(title: "Play on iPhone", systemImage: "iphone")
      }.frame(minHeight: 44)
    }
  }

  @ViewBuilder
  private var nativeCopyActions: some View {
    // A received copy has no server download to start, retry or remove: the phone sends it and
    // the only local action is deleting it.
    if hasLocalCopy {
      if primaryDestination != .watch {
        playOnWatchButton
      }
      Button(role: .destructive) {
        confirmsRemoval = true
      } label: {
        WatchCenteredActionLabel(title: "Remove from Watch", systemImage: "trash")
      }.frame(minHeight: 44).disabled(busy)
    }
  }

  @ViewBuilder
  private var watchActions: some View {
    if watchAccountMatches {
      if primaryDestination != .watch {
        playOnWatchButton
      }
      if let group = downloadGroup {
        downloadedGroupActions(group)
      } else {
        startDownloadButton
      }
    } else {
      NavigationLink("Set up Watch") { WatchAccountView() }.frame(minHeight: 44)
    }
  }

  private var playOnWatchButton: some View {
    Button {
      play(on: .watch)
    } label: {
      WatchCenteredActionLabel(title: "Play on Watch", systemImage: "applewatch")
    }.frame(minHeight: 44)
  }

  @ViewBuilder
  private func downloadedGroupActions(_ group: WatchDownloadGroup) -> some View {
    if model.downloadPresentation(for: group).canRetry {
      Button {
        showsActions = false
        Task {
          guard watchAccountMatches else { return }
          await model.retry(group: group)
        }
      } label: {
        WatchCenteredActionLabel(title: "Retry download", systemImage: "arrow.clockwise")
      }.frame(minHeight: 44)
    }
    Button(role: .destructive) {
      showsActions = false
      working = true
      Task {
        defer { working = false }
        guard watchAccountMatches else { return }
        await model.delete(group: group)
      }
    } label: {
      WatchCenteredActionLabel(title: "Remove from Watch", systemImage: "trash")
    }.frame(minHeight: 44)
  }

  private var startDownloadButton: some View {
    Button {
      showsActions = false
      startingDownload = true
      Task {
        defer { startingDownload = false }
        guard watchAccountMatches else { return }
        await model.download(selection, title: title)
      }
    } label: {
      WatchCenteredActionLabel(title: "Download to Watch", systemImage: "arrow.down.circle")
    }.frame(minHeight: 44)
  }

  private func resumeOnWatch() {
    guard !busy else { return }
    working = true
    Task {
      defer { working = false }
      guard watchAccountMatches, model.currentSelection == selection else { return }
      await model.resume()
      if isVisible && watchAccountMatches && model.currentSelection == selection {
        presentation.isPresented = true
      }
    }
  }

  private func play(on destination: WatchPlaybackDestination) {
    guard !busy else { return }
    showsActions = false
    pendingPhoneRequest = nil
    working = true
    Task {
      defer { working = false }
      if destination == .watch {
        guard watchSupported, watchAccountMatches else { return }
        let started = await model.play(selection)
        // A stream is still buffering here, so waiting for audible audio left the screen unchanged
        // and every retry restarted the stream. The player shows loading and any failure itself.
        if started && isVisible && watchAccountMatches && model.currentSelection == selection {
          presentation.isPresented = true
        }
      } else {
        guard phoneAvailable, let previous = companion.snapshot, let originalStamp = previous.accountStamp else {
          model.setMessage("Open this library in Whirr on your iPhone to play.")
          return
        }
        let previousEvent = companion.lastCommandEvent?.id
        // Continue on iPhone is the ABS peer handoff. A native episode playing here stops instead,
        // and its start command hands the phone the Watch's position.
        if model.currentSelection == selection && nativeSelection == nil {
          await model.continueOnPhone()
        } else {
          let handed = model.currentSelection != nil ? await model.stopForPhoneStart(of: selection) : nil
          guard phoneAvailable, companion.snapshot?.accountStamp == previous.accountStamp else { return }
          _ = await companion.send(selection: selection, action: .play, value: handed)
        }
        guard isVisible, phoneAvailable, companion.snapshot?.accountStamp == originalStamp,
          companion.lastCommandEvent?.id != previousEvent, companion.lastOutcome == .sent
        else { return }
        pendingPhoneRequest = (originalStamp, previous.generatedAt)
        presentConfirmedPhonePlayback()
      }
    }
  }

  private func presentConfirmedPhonePlayback() {
    guard isVisible, let pending = pendingPhoneRequest, phoneAvailable, !companion.snapshotIsStale,
      WatchNavigationPolicy.shouldPresentPhonePlayer(
        selection: selection, accountStamp: pending.stamp, snapshot: companion.snapshot, newerThan: pending.snapshotDate
      )
    else { return }
    pendingPhoneRequest = nil
    presentation.isPresented = true
  }
}
