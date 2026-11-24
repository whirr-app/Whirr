import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct SearchRecentActionPresentation: Equatable {
  let title: String
  let role: MediaActionRole

  var buttonRole: ButtonRole? {
    role == .destructive ? .destructive : nil
  }
}

extension SearchViewPresentation {
  static let clearRecentAction = SearchRecentActionPresentation(
    title: SearchCopy.clearRecentsButtonTitle, role: .destructive)
}

/// The idle screen, shown before anything is typed. Lists the user's recent searches,
/// most-recently-used first, when there are any; otherwise a quiet search prompt over a
/// magnifying-glass watermark. Selecting a recent re-runs it through `SearchModel.selectRecent`;
/// the clear-all control and per-row swipe-to-delete go through `clearRecents()`/
/// `clearRecent(_:)`, and are rendered only when there are recents to clear.
struct SearchIdleView: View {
  let recents: [RecentSearchQuery]
  let onSelectRecent: (RecentSearchQuery) -> Void
  let onClearRecent: (RecentSearchQuery) -> Void
  let onClearRecents: () -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var availableWidth: CGFloat = 0

  private var pageInset: CGFloat {
    SearchViewPresentation.pageInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  @ViewBuilder
  var body: some View {
    if SearchViewPresentation.showsIdleEmptyState(recents: recents) {
      ZStack {
        Image(systemName: SearchViewPresentation.idleSystemImage)
          .font(.system(size: SearchViewPresentation.idleWatermarkPointSize, weight: .thin))
          .foregroundStyle(WhirrColorToken.brandInk.color)
          .opacity(SearchViewPresentation.idleWatermarkOpacity)
          .accessibilityHidden(true)

        Text(SearchViewPresentation.idlePrompt)
          .font(WhirrTypeToken.title.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List {
        Section {
          ForEach(recents) { recent in
            Button {
              onSelectRecent(recent)
            } label: {
              Label(recent.displayQuery, systemImage: "clock")
                .font(WhirrTypeToken.body.font)
                .frame(
                  maxWidth: SearchViewPresentation.recentRowFillsRow ? .infinity : nil,
                  alignment: .leading
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .editorialCardListRow(.neutral, horizontalInset: pageInset)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing) {
              Button(role: SearchViewPresentation.clearRecentAction.buttonRole) {
                onClearRecent(recent)
              } label: {
                Text(SearchViewPresentation.clearRecentAction.title)
              }
              .tint(.red)
            }
            .contextMenu {
              Button(role: SearchViewPresentation.clearRecentAction.buttonRole) {
                onClearRecent(recent)
              } label: {
                Text(SearchViewPresentation.clearRecentAction.title)
              }
            }
          }
        } header: {
          HStack {
            Text(SearchCopy.recentSearchesHeader)
              .font(WhirrTypeToken.display.font)
            Spacer()
            if SearchViewPresentation.showsClearRecents(recents: recents) {
              Button(SearchCopy.clearRecentsButtonTitle) {
                onClearRecents()
              }
              .font(WhirrTypeToken.caption.font)
              .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, pageInset)
          .padding(.top, WhirrSpacing.medium)
          .padding(.bottom, WhirrSpacing.xSmall)
          .textCase(nil)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
      .primaryScrollEdgeEffect()
      .scrollDismissesKeyboard(
        SearchViewPresentation.idleScrollDismissal
      )
      .onGeometryChange(for: CGFloat.self) { geometry in
        geometry.size.width
      } action: { width in
        availableWidth = width
      }
    }
  }
}
