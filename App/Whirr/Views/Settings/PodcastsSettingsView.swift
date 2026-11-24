import AppModel
import DesignSystem
import SwiftUI

/// Which sections the Podcasts tab's All layout shows, and in what order, driving the preferences
/// `PodcastsView` reads (`PodcastsRootSectionVisibility`, `PodcastsRootSectionOrder`). The same
/// always-editing checklist as `HomeSettingsView`; see it for why the checkmark is drawn, and why
/// every row also has Move Up / Move Down (WCAG SC 2.5.7).
struct PodcastsSettingsView: View {
  @AppStorage(PodcastsRootSectionVisibility.storageKey) private var hiddenSections = ""
  @AppStorage(PodcastsRootSectionOrder.storageKey) private var sectionOrder = ""

  private var sections: [PodcastsRootSection] { PodcastsRootSectionOrder.ordered(in: sectionOrder) }

  var body: some View {
    List {
      Section {
        ForEach(sections, id: \.self) { section in
          row(for: section)
            .accessibilityIdentifier(
              PodcastsViewPresentation.sectionRowAccessibilityIDPrefix + section.rawValue
            )
            .contextMenu { reorderItems(for: section) }
            .accessibilityAction(named: Text(SettingsCopy.moveSectionUp)) { step(section, by: -1) }
            .accessibilityAction(named: Text(SettingsCopy.moveSectionDown)) { step(section, by: 1) }
        }
        .onMove(perform: move)
      } header: {
        Text(SettingsCopy.homeSectionsHeader)
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.editMode, .constant(.active))
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(PodcastsViewPresentation.sectionsSettingsTitle)
  }

  private func row(for section: PodcastsRootSection) -> some View {
    let isVisible = PodcastsRootSectionVisibility.isVisible(section, in: hiddenSections)
    return Button {
      hiddenSections = PodcastsRootSectionVisibility.updating(
        hiddenSections, section: section, isVisible: isVisible == false)
    } label: {
      HStack(spacing: WhirrSpacing.small) {
        // No label: the row's `isSelected` trait says it. Palette rendering as `HomeSettingsView`.
        Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
          .symbolRenderingMode(.palette)
          .foregroundStyle(
            isVisible ? AppChrome.onTint : WhirrColorToken.textSecondary.color,
            AppChrome.brandTint
          )
          .imageScale(.large)
          .accessibilityHidden(true)
        Text(PodcastsViewPresentation.rootSectionTitle(section))
          .foregroundStyle(WhirrColorToken.textPrimary.color)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isVisible ? .isSelected : [])
  }

  @ViewBuilder
  private func reorderItems(for section: PodcastsRootSection) -> some View {
    Button(SettingsCopy.moveSectionUp, systemImage: "arrow.up") { step(section, by: -1) }
      .disabled(PodcastsRootSectionOrder.canStep(sectionOrder, section: section, by: -1) == false)
    Button(SettingsCopy.moveSectionDown, systemImage: "arrow.down") { step(section, by: 1) }
      .disabled(PodcastsRootSectionOrder.canStep(sectionOrder, section: section, by: 1) == false)
  }

  private func step(_ section: PodcastsRootSection, by offset: Int) {
    sectionOrder = PodcastsRootSectionOrder.stepping(sectionOrder, section: section, by: offset)
  }

  private func move(fromOffsets: IndexSet, toOffset: Int) {
    sectionOrder = PodcastsRootSectionOrder.moving(
      sectionOrder, fromOffsets: fromOffsets, toOffset: toOffset)
  }
}
