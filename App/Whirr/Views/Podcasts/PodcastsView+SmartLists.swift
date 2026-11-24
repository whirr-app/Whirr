import AppModel
import DesignSystem
import SwiftUI

extension PodcastsView {
  /// How many lists exist, for the placeholder decision: a list is content.
  var smartListCount: Int {
    guard let model = smartLists?.model, model.isAvailable else { return 0 }
    return model.lists.count
  }

  func smartListsSectionIsDrawn(showsSectionIsReachable: Bool) -> Bool {
    guard let model = smartLists?.model else { return false }
    let hasOtherContent =
      listeningModel.continueListening.isEmpty == false
      || latestModel.podcastEpisodes.isEmpty == false
      || showsSectionIsReachable
    return SmartListsPresentation.sectionIsDrawn(
      isAvailable: model.isAvailable, listCount: model.lists.count,
      hasOtherContent: hasOtherContent)
  }

  @ViewBuilder
  func smartListsSection(isFirst: Bool) -> some View {
    if let access = smartLists {
      SmartListsSectionView(
        model: access.model,
        coverClient: coverClient,
        playback: playback,
        horizontalInset: pageColumnInset,
        onOpenList: onOpenSmartList,
        onPlayList: { listID in Task { _ = await access.play(listID: listID) } },
        onEditList: { listID in
          smartListEditorRequest = SmartListEditorRequest(
            mode: .edit(listID: listID), template: .blank)
        },
        onManage: onOpenSmartLists,
        onCreate: {
          smartListEditorRequest = SmartListEditorRequest(mode: .create, template: .blank)
        }
      )
      .padding(.top, HomePodcastsBrowseLayout.shelfTopSpacing(isFirst: isFirst))
    }
  }
}
