import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The copy and states every supplement surface shares, and the model's single-file request.
@MainActor
@Suite struct ItemSupplementsModelTests {

  private func supplement(
    _ filename: String?, ino: String = "900", size: Int64 = 4_200_000,
    state: ItemSupplementFileState = .notDownloaded
  ) -> ItemSupplement {
    ItemSupplement(
      serverFileIno: ino, filename: filename, sizeBytes: size, lastViewedPage: nil, fileState: state)
  }

  @Test func theTitleIsTheFilenameUnlessItIsGeneric() {
    #expect(
      ItemSupplementPresentation.title(for: supplement("Maps of the Shattered Realm.pdf"))
        == "Maps of the Shattered Realm")
    for generic in ["supplement.pdf", "Bonus.PDF", "booklet.pdf", "01.pdf", "  ", "Accompanying_Material.pdf"] {
      #expect(ItemSupplementPresentation.title(for: supplement(generic)) == "Companion PDF", "\(generic)")
    }
    #expect(ItemSupplementPresentation.title(for: supplement(nil)) == "Companion PDF")
  }

  @Test func severalPDFsReadAsACountAndAMenuOfSupplements() {
    let two = [supplement("a.pdf", ino: "1"), supplement("b.pdf", ino: "2")]
    #expect(ItemSupplementPresentation.rowTitle(for: two) == "2 PDFs")
    #expect(ItemSupplementPresentation.menuLabel(count: 2) == "Supplements…")
    #expect(ItemSupplementPresentation.menuLabel(count: 1) == "View PDF")
  }

  @Test func theTrailingStateFollowsTheFile() {
    let url = URL(fileURLWithPath: "/tmp/maps.pdf")
    typealias P = ItemSupplementPresentation
    #expect(P.trailing(for: supplement("a.pdf", size: 1_000_000), isOffline: false) == .size(P.sizeText(1_000_000)))
    #expect(
      P.trailing(for: supplement("a.pdf", state: .downloading(progress: 0.4)), isOffline: false) == .progress(0.4))
    #expect(P.trailing(for: supplement("a.pdf", state: .waitingForWiFi), isOffline: false) == .waitingForWiFi)
    #expect(P.trailing(for: supplement("a.pdf", state: .ready(fileURL: url)), isOffline: true) == .none)
    #expect(P.trailing(for: supplement("a.pdf"), isOffline: true) == .unavailableOffline)
    #expect(P.trailing(for: supplement("a.pdf", state: .failed), isOffline: false) == .failed)
  }

  @Test func theViewerStateFollowsTheFile() {
    let url = URL(fileURLWithPath: "/tmp/maps.pdf")
    typealias P = ItemSupplementPresentation
    #expect(
      P.viewerState(for: supplement("a.pdf", state: .ready(fileURL: url)), isOffline: true) == .ready(fileURL: url))
    #expect(P.viewerState(for: supplement("a.pdf", state: .waitingForWiFi), isOffline: false) == .waitingForWiFi)
    #expect(P.viewerState(for: supplement("a.pdf"), isOffline: true) == .unavailableOffline)
    #expect(P.viewerState(for: supplement("a.pdf"), isOffline: false) == .downloading(progress: 0))
    #expect(P.viewerState(for: supplement("a.pdf", state: .failed), isOffline: false) == .failed)
  }

  @Test func onlyProvenUnreachabilityIsOffline() {
    #expect(ItemSupplementPresentation.isOffline(.unreachable(.noNetworkPath, since: Date())))
    #expect(ItemSupplementPresentation.isOffline(.unknown) == false)
    #expect(ItemSupplementPresentation.isOffline(.reachable) == false)
    #expect(ItemSupplementPresentation.isOffline(nil) == false)
  }

  @Test func preparingRequestsOnlyAFileThatIsNotAlreadyComing() async {
    let intents = FakeDownloadIntents()
    let model = ItemSupplementsModel(
      itemID: "item-1", reading: NoOpItemSupplementReading(), downloadIntents: intents)

    await model.prepare(supplement("a.pdf", state: .waitingForWiFi))
    await model.prepare(supplement("a.pdf", state: .ready(fileURL: URL(fileURLWithPath: "/tmp/a.pdf"))))
    #expect(intents.calls.isEmpty)

    await model.prepare(supplement("a.pdf", ino: "900"))
    #expect(intents.calls == [.requestSupplementDownload(itemID: "item-1", fileIno: "900")])
    #expect(model.actionErrorMessage == nil)
  }
}
