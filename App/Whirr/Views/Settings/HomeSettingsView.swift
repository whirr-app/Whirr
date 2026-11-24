import AppModel
import DesignSystem
import SwiftUI

/// Which Home shelves to show, and in what order, driving the preferences `HomeView` reads
/// (`HomeSectionVisibility`, `HomeSectionOrder`). Permanently in edit mode; every change writes
/// straight through to `@AppStorage`.
///
/// A handle drag is still a drag (WCAG SC 2.5.7), so every row also has Move Up / Move Down: in a
/// context menu for a pointer, and as accessibility actions for VoiceOver, which can't reach a
/// context menu on a combined row element.
///
/// The checkmark is drawn, not `List(selection:)`: a selection binding takes the long press, so
/// `.contextMenu` never fires (verified on iOS 26.5, edit mode on or off).
struct HomeSettingsView: View {
  @AppStorage(HomeSectionVisibility.storageKey) private var hiddenSections = ""
  @AppStorage(HomeSectionOrder.storageKey) private var sectionOrder = ""
  @AppStorage(HomeSectionVisibility.continueCardOpenOnTapStorageKey)
  private var opensContinueCardImmediately = true

  private var sections: [HomeMoreSection] { HomeSectionOrder.ordered(in: sectionOrder) }

  var body: some View {
    List {
      Section {
        ForEach(sections, id: \.self) { section in
          row(for: section)
            .accessibilityIdentifier(ScreenAccessibilityID.homeSectionRowPrefix + section.rawValue)
            .contextMenu { reorderItems(for: section) }
            .accessibilityAction(named: Text(SettingsCopy.moveSectionUp)) { step(section, by: -1) }
            .accessibilityAction(named: Text(SettingsCopy.moveSectionDown)) { step(section, by: 1) }
        }
        .onMove(perform: move)
      } header: {
        Text(SettingsCopy.homeSectionsHeader)
      }

      Section {
        Toggle(
          SettingsCopy.continueCardOpenOnTapTitle,
          isOn: $opensContinueCardImmediately
        )
        .tint(AppChrome.brandTint)
      } header: {
        Text(SettingsCopy.continueListeningHeader)
      } footer: {
        Text(SettingsCopy.continueCardOpenOnTapFooter)
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.editMode, .constant(.active))
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
    .navigationTitle(SettingsCopy.homeScreenRowTitle)
  }

  private func row(for section: HomeMoreSection) -> some View {
    let isVisible = HomeSectionVisibility.isVisible(section, in: hiddenSections)
    return Button {
      hiddenSections = HomeSectionVisibility.updating(
        hiddenSections, section: section, isVisible: isVisible == false)
    } label: {
      HStack(spacing: WhirrSpacing.small) {
        // No label: the row's `isSelected` trait says it, and VoiceOver would stop twice.
        //
        // Palette rendering: `checkmark.circle.fill` knocks the tick out of the disc, so one
        // `brandTint` fill gives a navy tick on a navy disc that reads as disabled. The tick takes
        // `onTint`, the disc the navy (as a switch track with a white thumb).
        //
        // Styles are per layer (`checkmark.circle.fill` has two, `circle` one), so the first must
        // suit an empty ring: `.clear` when unselected, invisible on any background.
        Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
          .symbolRenderingMode(.palette)
          .foregroundStyle(
            isVisible ? AppChrome.onTint : WhirrColorToken.textSecondary.color,
            AppChrome.brandTint
          )
          .imageScale(.large)
          .accessibilityHidden(true)
        Text(HomeCopy.sectionTitle(section))
          .foregroundStyle(WhirrColorToken.textPrimary.color)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isVisible ? .isSelected : [])
  }

  @ViewBuilder
  private func reorderItems(for section: HomeMoreSection) -> some View {
    Button(SettingsCopy.moveSectionUp, systemImage: "arrow.up") { step(section, by: -1) }
      .disabled(HomeSectionOrder.canStep(sectionOrder, section: section, by: -1) == false)
    Button(SettingsCopy.moveSectionDown, systemImage: "arrow.down") { step(section, by: 1) }
      .disabled(HomeSectionOrder.canStep(sectionOrder, section: section, by: 1) == false)
  }

  private func step(_ section: HomeMoreSection, by offset: Int) {
    sectionOrder = HomeSectionOrder.stepping(sectionOrder, section: section, by: offset)
  }

  private func move(fromOffsets: IndexSet, toOffset: Int) {
    sectionOrder = HomeSectionOrder.moving(
      sectionOrder, fromOffsets: fromOffsets, toOffset: toOffset)
  }
}
