import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

extension ExpandedPlayerView {
  var upNextPlacement: InlineUpNextPresentation.Placement {
    InlineUpNextPresentation.placement(
      widthClass: horizontalSizeClass == .regular ? .regular : .compact,
      isCompactHeight: verticalSizeClass == .compact,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  private var upNextSheetBinding: Binding<Bool> {
    Binding(
      get: {
        InlineUpNextPresentation.isSheetPresented(
          isShowingUpNext: isShowingUpNext, placement: upNextPlacement)
      },
      set: { isShowingUpNext = $0 })
  }

  func upNextQueue(style: ListeningQueueSheet.Style) -> some View {
    PlayerUpNextSheet(
      model: deferredQueue.resolve(makeListeningQueueModel),
      coverClient: coverClient,
      playback: playback,
      navigation: navigation,
      onPlayNowCommitted: onPlayNowCommitted,
      onOpenEpisode: openEpisodeFromQueueAction,
      style: style,
      isPresented: $isShowingUpNext
    )
  }

  private var openEpisodeFromQueueAction: ((NavigationModel.PodcastEpisodeRef) -> Void)? {
    guard episodeCard != nil else { return nil }
    return { ref in openEpisodeFromQueue(ref) }
  }

  /// The inline queue stays put under the card; the queue sheet leaves first.
  private func openEpisodeFromQueue(_ ref: NavigationModel.PodcastEpisodeRef) {
    guard upNextSheetBinding.wrappedValue else {
      presentedEpisodeCard = ref
      return
    }
    episodeCardAfterQueue = ref
    isShowingUpNext = false
  }

  private func upNextSheetDismissed() {
    onQueueDismissed()
    guard let ref = episodeCardAfterQueue else { return }
    episodeCardAfterQueue = nil
    presentedEpisodeCard = ref
  }

  /// Raised from the Up Next quick action, inside this page's own hierarchy with the same system
  /// sheet treatment as the sheets above, so nothing competes with the page's ScrollView.
  func upNextSheetPresentation<Content: View>(_ content: Content) -> some View {
    content
      .sheet(isPresented: upNextSheetBinding, onDismiss: upNextSheetDismissed) {
        upNextQueue(style: .sheet)
          .queueDetents(accent: Self.neutralControlTint, selection: $upNextDetent)
      }
  }

  /// The sheet reports its own dismissal; the inline queue has only this flag.
  func upNextVisibilityChanged(_ isPresented: Bool) {
    if isPresented {
      if InlineUpNextPresentation.freezesCommittedIdentity(upNextPlacement) {
        onQueuePresented()
      }
    } else if upNextPlacement == .inline {
      onQueueDismissed()
    }
  }
}
