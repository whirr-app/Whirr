import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import UIKit

/// One A-Z jump. The serial makes a repeat of the same letter a new request.
struct LibraryBrowseJumpRequest: Equatable {
  let targetID: String
  let serial: Int
}

/// The UIKit scroll callbacks the host forwards, and the `ScrollPhase` each one stands for.
///
/// `.tracking` is never produced: UIKit reports a drag only once it starts, so a finger resting on
/// the grid without moving does not defer publication. `LibraryScrollActivity` collapses every
/// moving phase to one boolean, so that is the only difference from the SwiftUI grid.
nonisolated enum LibraryBrowseScrollEvent: Equatable {
  case willBeginDragging
  case didEndDragging(willDecelerate: Bool)
  case willBeginDecelerating
  case didEndDecelerating
  case beganAnimatedScroll
  case didEndScrollingAnimation
  case didScrollToTop

  var phase: ScrollPhase? {
    switch self {
    case .willBeginDragging: .interacting
    // A drag that hands over to deceleration reports `willBeginDecelerating` next; answering
    // `.idle` here would lift deferral for one frame in the middle of a fling.
    case .didEndDragging(let willDecelerate): willDecelerate ? nil : .idle
    case .willBeginDecelerating: .decelerating
    case .didEndDecelerating: .idle
    case .beganAnimatedScroll: .animating
    case .didEndScrollingAnimation, .didScrollToTop: .idle
    }
  }
}

/// What a hosted tile needs from the Library root. The closures are read through the controller at
/// call time, so a cell configured before the root last re-rendered still calls the current ones.
struct LibraryBrowseCollectionTileContext {
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelectTitle: (ItemSummary) -> Void
  let onSelectEntity: (LibraryEntityGroup) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  let onLoadMore: () -> Void
}

/// The regular-width Library scroll host: one `UICollectionView`, reused cells, one flat layout
/// with a section per letter.
///
/// The SwiftUI environment crosses into hosted cells only as traits, so `LibraryBrowseHostedCell`
/// forwards the three non-trait values a tile reads (app tint, two book-zoom keys).
struct LibraryBrowseCollectionView<Controls: View, StateContent: View>: UIViewControllerRepresentable {
  let snapshot: LibraryBrowseCollectionSnapshot
  let tileContext: LibraryBrowseCollectionTileContext
  let scrollToTopRequest: Int
  let jumpRequest: LibraryBrowseJumpRequest?
  let onRefresh: () async -> Void
  let onScrollPhaseChange: (ScrollPhase) -> Void
  @ViewBuilder let controls: Controls
  @ViewBuilder let stateContent: StateContent

  func makeUIViewController(context: Context) -> LibraryBrowseCollectionController {
    let controller = LibraryBrowseCollectionController()
    controller.scrollToTopRequest = scrollToTopRequest
    controller.lastJumpSerial = jumpRequest?.serial
    return controller
  }

  func updateUIViewController(_ controller: LibraryBrowseCollectionController, context: Context) {
    controller.tileContext = tileContext
    controller.onRefresh = onRefresh
    controller.onScrollPhaseChange = onScrollPhaseChange
    controller.controls = AnyView(controls)
    controller.stateContent = AnyView(stateContent)
    controller.update(
      environment: LibraryBrowseHostedCellEnvironment(
        bookZoomTransitionContext: context.environment.bookZoomTransitionContext,
        bookZoomActiveSources: context.environment.bookZoomActiveSources))

    let transaction = context.transaction
    controller.apply(
      snapshot,
      animation: transaction.disablesAnimations ? nil : transaction.animation)

    if scrollToTopRequest != controller.scrollToTopRequest {
      controller.scrollToTopRequest = scrollToTopRequest
      controller.scrollToTop(animated: context.environment.accessibilityReduceMotion == false)
    }
    if let jumpRequest, jumpRequest.serial != controller.lastJumpSerial {
      controller.lastJumpSerial = jumpRequest.serial
      controller.jump(
        to: jumpRequest.targetID,
        animated: context.environment.accessibilityReduceMotion == false)
    }
  }

  static func dismantleUIViewController(
    _ controller: LibraryBrowseCollectionController, coordinator: Void
  ) {
    controller.retireScrollPhase()
  }
}
