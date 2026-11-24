import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// The account graph `bind` composes: the Companion handoff peer and its asker, the native pause and
/// pending-progress gates, the catalogue publisher, and artwork. `bind` keeps the account stamp and
/// the epoch it captures once, and passes them in, so every phase checks the same pair.
extension WatchCompanionRuntime {
  /// Installs the Companion peer handoff and the asker that judges a Watch request against stored
  /// listens. Returns the library reader the pending-progress gate reuses.
  func bindHandoff(
    actions: CompanionPlaybackActions, dependencies: AppDependencies, playback: PlaybackModel
  ) -> any LibraryReading {
    let peer = CompanionPlaybackHandoff(playback: playback, actions: actions)
    handoffEndpoint = WatchPhoneHandoffEndpoint(
      authenticatedStamp: { [weak self] in self?.authenticatedStamp },
      peer: WatchPhoneHandoffEndpoint.Peer(
        state: { peer.peerState() }, pause: { peer.pauseForPeer() }, flush: { await peer.flushProgress() }))
    companionHandoff = peer
    let library = dependencies.library
    phoneLastListened = { itemID, episodeID in
      library.currentAudioProgress(itemId: itemID, episodeId: episodeID)?.changedAt
    }
    handoffAsker = WatchPhoneHandoffAsker(
      report: { [weak self] in self?.playingReport },
      authenticatedStamp: { [weak self] in self?.authenticatedStamp },
      send: { data, wait in
        await WatchPeerMessageSender.send(data, key: WatchHandoffRequest.transportKey, timeout: wait)
      },
      storedListen: { itemID, episodeID in library.currentAudioProgress(itemId: itemID, episodeId: episodeID)?.changedAt
      })
    return library
  }

  /// The native pause gate, the pending-progress inbox and gate, and the phone-start authorization
  /// the player calls. Both gates answer a start with the Watch's newest position.
  func bindProgressGates(library: any LibraryReading, playback: PlaybackModel) {
    if let database = DatabaseHardware.sharedIfAvailable() {
      let episodes = RSSEpisodeStore(database: database)
      let state = RSSEpisodeStateStore(database: database)
      nativeStartGate = WatchNativeStartGate(
        report: { [weak self] in self?.playingReport },
        send: { data, wait in
          await WatchPeerMessageSender.send(
            data, key: WatchNativePauseRequest.transportKey,
            replyLimit: WatchNativePauseReply.maxWireBytes, timeout: wait)
        },
        applyListen: { selection, position, lastListenedAt in
          // The reply names the episode by feed and identity key, so the row is resolved the same
          // way a local start is; `duration: nil` lets the store use the episode's own duration.
          guard let feedId = Int64(selection.feedID), feedId > 0 else { return }
          let found = try? await episodes.fetchEpisodeIDs(
            feedId: feedId, identityKeys: [selection.episodeID])
          guard let episodeId = found?[selection.episodeID] else { return }
          _ = try? await state.applyPeerListen(
            episodeId: episodeId, position: position, finished: false, listenedAt: lastListenedAt,
            duration: nil, now: Date())
        })
    }
    let inbox = WatchPendingProgressInbox(currentStamp: { [weak self] in self?.authenticatedStamp })
    pendingProgressInbox = inbox
    pendingProgressGate = WatchPendingProgressStartGate(
      inbox: inbox,
      // A title the Watch took over is still loaded here, but its position is stale, so the
      // Watch's pending progress is weighed for it as for any other start.
      isActive: { [weak playback] itemID, episodeID in
        guard let playback else { return false }
        return playback.isLoaded(itemID: itemID, episodeID: episodeID)
          && !playback.nextPlayStartsFresh(itemID: itemID, episodeID: episodeID)
      },
      query: { await Self.queryPendingProgress($0) },
      stored: { itemID, episodeID in library.currentAudioProgress(itemId: itemID, episodeId: episodeID) })
    playback.authorizePlaybackStart = { [weak self] itemID, episodeID in
      guard let self else { return .allowed(position: nil) }
      return await self.authorizePhoneStart(itemID: itemID, episodeID: episodeID)
    }
  }

  /// The publisher the account publishes through. Its publish closure drops a snapshot that belongs
  /// to an account other than the one bound here.
  func makeCataloguePublisher(
    epoch: Int, stamp: WatchAccountStamp, actions: CompanionPlaybackActions, playback: PlaybackModel,
    dependencies: AppDependencies,
    audioActivationWasRefused: @escaping WatchCataloguePublisher.AudioActivationRefusal
  ) -> WatchCataloguePublisher {
    WatchCataloguePublisher(
      dependencies: dependencies, playback: playback,
      publish: { [weak self, weak actions, weak playback] snapshot in
        guard let self, self.accountEpoch == epoch else { return }
        guard snapshot.accountStamp == nil || snapshot.accountStamp == stamp else {
          self.latestSnapshot = nil
          self.bridge.unbind()
          return
        }
        self.noteResume(snapshot)
        // Every phone playback change republishes the catalogue; a listen the Watch reported while
        // this phone played the episode is applied here once the phone stops.
        Task { @MainActor [weak self] in await self?.nativeProgressInbox?.phoneSessionEnded() }
        // A title finished here stops playback and republishes, which removes it from the Watch.
        self.absSendPublisher?.refresh()
        let enriched = Self.enriched(snapshot, authenticatedStamp: self.authenticatedStamp)
        self.latestSnapshot = enriched
        self.bridge.publish(enriched)
        self.artworkSync?.update(snapshot: enriched)
        if let stamp = snapshot.accountStamp, let actions, let playback {
          self.bridge.bind(actions, accountStamp: stamp, currentSelection: Self.selectionReader(playback))
        } else {
          self.bridge.unbind()
        }
      }, audioActivationWasRefused: audioActivationWasRefused)
  }

  /// The covers the phone fetches for the Watch: the on-demand endpoint and the push sync.
  func bindArtwork(
    epoch: Int, stamp: WatchAccountStamp, artwork: any ArtworkServing, dependencies: AppDependencies
  ) {
    let sources = FollowedShowArtworkSources(reading: dependencies.nativePodcastShowsReading)
    artworkSources = sources
    let load = Self.thumbnailLoader(artwork: artwork, library: dependencies.library, sources: sources)
    artworkEndpoint = WatchPhoneArtworkEndpoint(
      currentStamp: { [weak self] in
        guard let self, self.accountEpoch == epoch else { return nil }
        return self.latestSnapshot?.accountStamp
      },
      load: load)
    startArtworkSync(
      stamp: stamp, load: load, library: dependencies.library,
      shows: dependencies.nativePodcastShowsReading)
  }

  private static func queryPendingProgress(_ query: WatchPendingProgressQuery) async -> WatchPendingProgressReport? {
    guard let data = try? WatchWireCodec.encode(query),
      let reply = await WatchPeerMessageSender.send(
        data, key: WatchPendingProgressQuery.transportKey, replyLimit: WatchPendingProgressReport.maxWireBytes,
        timeout: WatchPendingProgressStartGate.watchPendingProgressWait),
      let report = try? WatchWireCodec.decode(WatchPendingProgressReport.self, from: reply),
      report.accountStamp == query.accountStamp
    else { return nil }
    return report
  }
}
