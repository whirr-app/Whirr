import SwiftUI
import WatchPlayback
import WatchProtocol

struct ContentView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(WatchArtworkStore.self) private var artwork
  @State private var playerPresentation = WatchPlayerPresentation()

  var body: some View {
    NavigationStack {
      WatchHomeView()
        .navigationTitle("Whirr")
        .tint(WatchVisualStyle.accent)
        .watchPlayerToolbar()
    }
    .environment(artwork)
    .onChange(of: scenePhase) { _, phase in
      WatchRSSDiagnostics.log("scene_phase", ["phase": String(describing: phase)])
      // A suspended Watch app may not run again soon; hand over a held inventory, then send closed
      // rows while it still can.
      guard phase != .active else { return }
      Task {
        await model.suspendEpisodeSync()
        await model.offlineSync.reconcileOfflineProgress()
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await model.initialize()
      // A wrist raise is the one moment the Watch can tell the phone where its link stands.
      model.publishStatusReport()
      // Anything a background wake could not finish is caught up when the owner opens the app.
      model.resumeEpisodeSync()
      // Coming to the foreground is an upload opportunity; it never waits for the phone.
      Task { await model.offlineSync.reconcileOfflineProgress() }
      await model.refreshContinueListening()
    }
    .task(id: "\(navigationIdentity)|\(model.session.context?.epoch ?? -1)") {
      await artwork.configure(context: model.session.context, companion: companion)
    }
    .task(id: "\(artwork.generation)|\(artwork.coverRevisionEpoch)|\(model.downloadGroups.map(\.id))") {
      await artwork.pinDownloads(model.downloadGroups.map(\.selection))
    }
    .onChange(of: companion.snapshot, initial: true) { _, snapshot in
      artwork.learnCoverRevisions(from: snapshot)
    }
    .environment(playerPresentation)
    .sheet(isPresented: $playerPresentation.isPresented) {
      NavigationStack { UnifiedNowPlayingView() }
        .environment(playerPresentation).environment(artwork)
    }
    .onChange(of: navigationIdentity) { _, _ in playerPresentation.isPresented = false }
    .id(navigationIdentity)
    .sensoryFeedback(.success, trigger: companion.lastCommandEvent) { _, event in
      event?.outcome == .sent
    }
    // Unresolved deliveries may have succeeded, so they get copy but no error haptic.
    .sensoryFeedback(.error, trigger: companion.lastCommandEvent) { _, event in
      guard let event else { return false }
      return event.outcome != .sent && event.outcome != .unresolved
    }
  }

  private var navigationIdentity: String {
    let watch = try? model.account?.authenticatedStamp()
    let phone = companion.snapshot?.accountStamp
    return [
      watch?.accountIdentityHash, watch?.serverIdentityHash,
      phone?.accountIdentityHash, phone?.serverIdentityHash,
    ].map { $0 ?? "" }.joined(separator: "|")
  }
}
