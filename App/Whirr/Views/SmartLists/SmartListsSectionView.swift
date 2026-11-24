import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// The Podcasts tab's Smart Lists section: a heading that opens the Smart Lists screen and one row
/// per list. Lists are made on that screen; here an empty section offers the first one. Reads the
/// model in its own body, so a count or cover changing redraws this section and not the tab.
struct SmartListsSectionView: View {
  let model: SmartListsModel
  let coverClient: any ArtworkServing
  /// Read here so a list's button follows play and pause without redrawing the tab.
  let playback: PlaybackModel
  let horizontalInset: CGFloat
  let onOpenList: (Int64) -> Void
  let onPlayList: (Int64) -> Void
  let onEditList: (Int64) -> Void
  let onManage: () -> Void
  let onCreate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BrowseSectionHeaderView(
        title: SmartListsPresentation.sectionTitle,
        accessibilityHint: SmartListsPresentation.sectionHint,
        onSelect: onManage
      )
      .padding(.horizontal, horizontalInset)
      .padding(.bottom, HomePodcastsBrowseLayout.headerToContentSpacing)

      if model.lists.isEmpty {
        createRow
      } else {
        ForEach(model.lists) { list in
          let control = playControl(for: list)
          SmartListRowView(
            list: list, coverClient: coverClient, detail: .matchCount,
            onOpen: { onOpenList(list.id) }, playControl: control,
            onPlay: { perform(control, listID: list.id) }
          )
          .padding(.horizontal, horizontalInset)
          .padding(.vertical, WhirrSpacing.xSmall)
          .contentShape(Rectangle())
          .contextMenu {
            Button(
              SmartListsPresentation.playControlTitle(control),
              systemImage: control.systemImage
            ) { perform(control, listID: list.id) }
            .disabled(control == .start && list.matchCount == 0)
            Button(SmartListsPresentation.editTitleShort, systemImage: "slider.horizontal.3") {
              onEditList(list.id)
            }
          }
        }
      }
    }
  }

  private func playControl(for list: SmartListSummary) -> PodcastEpisodeCardPlayControl {
    SmartListsPresentation.playControl(
      isActive: list.isActive, hasLoadedEpisode: playback.nowPlayingIdentity != nil,
      isPlaybackIntended: playback.isPlaybackIntended)
  }

  /// Pause and Resume act on what is loaded, which is the list's run; Play starts the list.
  private func perform(_ control: PodcastEpisodeCardPlayControl, listID: Int64) {
    if control.startsNewSession {
      onPlayList(listID)
    } else {
      playback.togglePlayPause()
    }
  }

  private var createRow: some View {
    Button(action: onCreate) {
      HStack(spacing: WhirrSpacing.small) {
        ZStack {
          RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
            .fill(.quaternary)
          Image(systemName: "plus")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .frame(width: SmartListCoverMosaic.rowSize, height: SmartListCoverMosaic.rowSize)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(SmartListsPresentation.createTitle)
            .font(WhirrTypeToken.headline.font)
            .foregroundStyle(.primary)
          Text(SmartListsPresentation.emptyMessage)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, horizontalInset)
    .padding(.vertical, WhirrSpacing.xSmall)
    .accessibilityElement(children: .combine)
  }
}
