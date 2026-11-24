import AppModel
import Foundation
import Testing

@testable import Whirr

/// The Save Show to Audiobookshelf menu row and the view wiring around it. The model rules
/// (presence, mark, enable) are tested in Core. These tests pin the presentation row and the places
/// the view must and must not touch.
@Suite struct PodcastShowSaveShowViewTests {
  private static func menu(
    isNativeFeed: Bool = true, offersSaveShow: Bool = false
  ) -> [PodcastShowViewPresentation.ShowMenuItem] {
    PodcastShowViewPresentation.showMenu(
      filter: .all, unplayedCount: 1, playedCount: 1, downloadableCount: 1, removableCount: 1,
      isNativeFeed: isNativeFeed, offersSaveShow: offersSaveShow)
  }

  @Test func theRowIsOfferedOnlyWhenTheParameterSaysSo() {
    let id = PodcastShowMenuAction.saveShow.rawValue
    #expect(Self.menu(offersSaveShow: false).contains { $0.id == id } == false)
    #expect(Self.menu(offersSaveShow: true).contains { $0.id == id })
    // The default is off, so every existing call site is unchanged.
    let defaulted = PodcastShowViewPresentation.showMenu(
      filter: .all, unplayedCount: 1, playedCount: 1, downloadableCount: 1, removableCount: 1,
      isNativeFeed: true)
    #expect(defaulted.contains { $0.id == id } == false)
  }

  @Test func theRowSitsBesideShowSettingsAndAddsNoDivider() throws {
    let items = Self.menu(offersSaveShow: true)
    let settings = try #require(
      items.firstIndex { $0.id == PodcastShowMenuAction.openSettings.rawValue })
    let save = try #require(items.firstIndex { $0.id == PodcastShowMenuAction.saveShow.rawValue })
    #expect(save == settings + 1)
    #expect(items[save].group == items[settings].group)
    #expect(items.last?.id == PodcastShowMenuAction.unsubscribe.rawValue)
    #expect(items.filter { $0.group == items.last?.group }.count == 1)
    #expect(items[save].label == "Save Show to Server\u{2026}")
    #expect(items[save].isEnabled)
    #expect(items[save].isDestructive == false)
  }

  @Test func theRowNeverMentionsTheQueue() throws {
    let item = try #require(
      Self.menu(offersSaveShow: true).first {
        $0.id == PodcastShowMenuAction.saveShow.rawValue
      })
    #expect(item.id.contains("up-next") == false)
    #expect(item.id.localizedCaseInsensitiveContains("queue") == false)
    #expect(item.label.localizedCaseInsensitiveContains("up next") == false)
    #expect(item.label.localizedCaseInsensitiveContains("queue") == false)
    #expect(item.hint.localizedCaseInsensitiveContains("up next") == false)
    #expect(item.hint.localizedCaseInsensitiveContains("queue") == false)
  }

  // MARK: View wiring

  @Test func selectionEntryArmsTheMarkAndSetsSelectionAfterEditMode() throws {
    let selection = try Self.source("PodcastShowView+Selection.swift")
    let start = try #require(selection.range(of: "func beginShowSaveSelection()"))
    let end = try #require(selection.range(of: "var selectionTitle: String"))
    let body = String(selection[start.upperBound..<end.lowerBound])

    let arm = try #require(body.range(of: "model.serverSave.armShowSave()"))
    let edit = try #require(body.range(of: "editMode = .active"))
    let yield = try #require(body.range(of: "await Task.yield()"))
    let select = try #require(body.range(of: "selection.selected = [preselected]"))
    #expect(arm.lowerBound < edit.lowerBound)
    #expect(edit.lowerBound < yield.lowerBound)
    #expect(yield.lowerBound < select.lowerBound)
    #expect(body.contains("model.serverSave.showSavePreselectedEpisodeID"))
    // The user's filter and search are never changed by the entry.
    #expect(body.contains("model.filter") == false)
    #expect(body.contains("episodeQuery") == false)
  }

  private static func source(_ name: String) throws -> String {
    let source = try #require(ViewSourceScan.sources().first { $0.lastPathComponent == name })
    return try ViewSourceScan.executableText(of: source)
  }
}
