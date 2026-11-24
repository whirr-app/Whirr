import ABSApi
import AppModel
import Foundation
import Persistence
import Testing
import WatchProtocol

@testable import Whirr

@Suite("On Apple Watch presentation")
struct OnAppleWatchPresentationTests {
  @Test("each stored state and Watch report maps to the one sentence the screen says")
  func statusMapping() {
    func status(
      _ state: RSSWatchCopyState,
      removedBy: RSSWatchCopyRemovalInitiator? = nil,
      declineReason: RSSWatchDeclineReason? = nil,
      download: WatchEpisodeDownloadStatus? = nil,
      readiness: WatchAppReadiness = .canFetch
    ) -> OnAppleWatchStatus {
      OnAppleWatchPresentation.status(
        for: copy(state, removedBy: removedBy, declineReason: declineReason, download: download),
        readiness: readiness)
    }

    func downloading(
      _ state: WatchEpisodeDownloadStatus.State, progress: Double? = nil
    ) -> WatchEpisodeDownloadStatus {
      WatchEpisodeDownloadStatus(revision: 1, state: state, progress: progress)
    }

    #expect(status(.wanted) == .waitingForWatch)
    #expect(status(.waitingForWatch) == .waitingForWatch)
    #expect(status(.sending) == .waitingForWatch)
    #expect(status(.sending, download: downloading(.queued)) == .waitingForWatch)
    #expect(
      status(.sending, download: downloading(.downloading, progress: 0.42))
        == .downloadingOnWatch(progress: 0.42))
    #expect(
      status(.sending, download: downloading(.downloading)) == .downloadingOnWatch(progress: nil))
    #expect(
      status(.sending, download: downloading(.waitingForNetwork)) == .waitingForWiFiOnWatch)
    #expect(status(.sending, download: downloading(.failed)) == .couldNotDownload)
    #expect(status(.delivered) == .onWatch)
    #expect(status(.declined, declineReason: .storageFull) == .watchStorageFull)
    #expect(status(.declined, declineReason: .invalid) == .couldNotDownload)
    #expect(status(.failed) == .couldNotDownload)
    #expect(status(.removed, removedBy: .watch) == .removedOnWatch)
  }

  @Test("a copy the Watch has not acknowledged reads the Watch app's readiness")
  func unacknowledgedCopyReadsReadiness() {
    func status(
      _ state: RSSWatchCopyState, download: WatchEpisodeDownloadStatus? = nil,
      readiness: WatchAppReadiness
    ) -> OnAppleWatchStatus {
      OnAppleWatchPresentation.status(
        for: copy(state, download: download), readiness: readiness)
    }
    let queued = WatchEpisodeDownloadStatus(revision: 1, state: .queued, progress: nil)

    for state: RSSWatchCopyState in [
      .wanted, .waitingForWatch, .sending,
    ] {
      #expect(status(state, readiness: .unknown) == .openWhirrOnWatch)
      #expect(status(state, readiness: .needsUpdate) == .updateWhirrOnWatch)
      #expect(status(state, readiness: .canFetch) == .waitingForWatch)
    }
    // The Watch admitted the offer, so its inventory is an acknowledgement whatever its build says.
    #expect(status(.sending, download: queued, readiness: .unknown) == .waitingForWatch)
    #expect(status(.sending, download: queued, readiness: .needsUpdate) == .waitingForWatch)
  }

  @Test("a Watch without the app reports that over every live state, and keeps a removal")
  func missingWatchAppOverridesLiveStates() {
    let downloading = WatchEpisodeDownloadStatus(
      revision: 1, state: .downloading, progress: 0.42)
    let live: [WatchEpisodeCopyRow] = [
      copy(.wanted),
      copy(.waitingForWatch),
      copy(.sending),
      copy(.sending, download: downloading),
      copy(.delivered),
      copy(.declined, declineReason: .storageFull),
      copy(.failed),
    ]

    for row in live {
      #expect(
        OnAppleWatchPresentation.status(for: row, readiness: .notInstalled)
          == .watchAppNotInstalled)
    }
    #expect(
      OnAppleWatchPresentation.status(
        for: copy(.removed, removedBy: .watch), readiness: .notInstalled) == .removedOnWatch)

    let rows = OnAppleWatchPresentation.rows(
      [
        copy(.delivered, id: 1, requestedAt: 20),
        copy(.removed, id: 2, removedBy: .watch, requestedAt: 10),
        copy(.removed, id: 3, removedBy: .phone, requestedAt: 30),
      ],
      readiness: .notInstalled)
    #expect(rows.map(\.id) == ["rss:1", "rss:2"])
    #expect(rows.map(\.status) == [.watchAppNotInstalled, .removedOnWatch])
    #expect(rows.map(\.canRemove) == [true, false])
  }

  @Test("the status copy is the screen's, never the store's raw name")
  func statusCopy() {
    #expect(OnAppleWatchStatus.openWhirrOnWatch.text == "Open Whirr on your Watch")
    #expect(OnAppleWatchStatus.updateWhirrOnWatch.text == "Update Whirr on your Watch")
    #expect(OnAppleWatchStatus.waitingForWatch.text == "Waiting for your Watch")
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: 0.42).text == "Downloading on Watch")
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: nil).text == "Downloading on Watch")
    #expect(OnAppleWatchStatus.waitingForWiFiOnWatch.text == "Waiting for Wi-Fi on Watch")
    #expect(OnAppleWatchStatus.onWatch.text == "On Watch")
    #expect(OnAppleWatchStatus.watchStorageFull.text == "Watch storage full")
    #expect(OnAppleWatchStatus.couldNotDownload.text == "Couldn’t download")
    #expect(OnAppleWatchStatus.removedOnWatch.text == "Removed on Watch")
    #expect(OnAppleWatchStatus.watchAppNotInstalled.text == "Whirr isn’t on your Watch")
    #expect(OnAppleWatchStatus.setUpWatch.text == "Set up Whirr on your Watch")
    #expect(OnAppleWatchStatus.notOnServer.text == "Not on the server")
    #expect(OnAppleWatchStatus.noAudioToDownload.text == "No audio to download")
  }

  /// A book names its parts once one is in; a single file, or none yet, does not.
  @Test("a multi-part book's download names its parts")
  func downloadingNamesParts() {
    func text(_ completed: Int, of total: Int) -> String {
      OnAppleWatchStatus.downloadingOnWatch(
        progress: 0.25, parts: OnAppleWatchParts(completed: completed, total: total)
      ).text
    }
    #expect(text(3, of: 12) == "Downloading on Watch · 3 of 12 parts")
    #expect(text(0, of: 12) == "Downloading on Watch")
    #expect(text(1, of: 1) == "Downloading on Watch")
  }

  @Test("only a failed download or a Watch removal offers an action")
  func recoveryActions() {
    #expect(OnAppleWatchStatus.couldNotDownload.action == .tryAgain)
    #expect(OnAppleWatchAction.tryAgain.title == "Try Again")
    #expect(OnAppleWatchStatus.removedOnWatch.action == .sendAgain)
    #expect(OnAppleWatchAction.sendAgain.title == "Send Again")

    for status: OnAppleWatchStatus in [
      .openWhirrOnWatch, .updateWhirrOnWatch, .waitingForWatch,
      .downloadingOnWatch(progress: nil), .downloadingOnWatch(progress: 0.42),
      .waitingForWiFiOnWatch, .onWatch, .watchStorageFull, .watchAppNotInstalled, .setUpWatch,
      .notOnServer, .noAudioToDownload,
    ] {
      #expect(status.action == nil)
    }
  }

  @Test("the Watch's fraction is a whole, clamped percent")
  func progressIsClampedAndWhole() {
    #expect(OnAppleWatchPresentation.percent(nil) == nil)
    #expect(OnAppleWatchPresentation.percent(.nan) == nil)
    #expect(OnAppleWatchPresentation.percent(0) == 0)
    #expect(OnAppleWatchPresentation.percent(0.424) == 42)
    #expect(OnAppleWatchPresentation.percent(1) == 100)
    #expect(OnAppleWatchPresentation.percent(1.4) == 100)
    #expect(OnAppleWatchPresentation.percent(-0.2) == 0)
  }

  @Test("a downloading row exposes the ring's fraction and speaks a whole percentage")
  func downloadRingFraction() {
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: nil).downloadProgressFraction == nil)
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: .nan).downloadProgressFraction == nil)
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: -0.2).downloadProgressFraction == 0)
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: 1.4).downloadProgressFraction == 1)
    #expect(
      OnAppleWatchStatus.downloadingOnWatch(progress: 0.424).downloadProgressFraction == 0.424)
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: 0.424).downloadPercentText == "42%")
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: nil).downloadPercentText == nil)

    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: nil).isDownloading)
    #expect(OnAppleWatchStatus.downloadingOnWatch(progress: 0.5).isDownloading)
    #expect(OnAppleWatchStatus.onWatch.isDownloading == false)
    #expect(OnAppleWatchStatus.onWatch.downloadProgressFraction == nil)
    #expect(OnAppleWatchStatus.onWatch.downloadPercentText == nil)
  }

  @Test("the remove swipe is the app's trash capsule, short-titled and fully named for VoiceOver")
  func removeSwipeIsTheSharedTrashCapsule() {
    let button = OnAppleWatchPresentation.removeSwipeButton

    #expect(button.label == "Remove", "the short title every other episode list draws")
    #expect(button.systemImage == "trash")
    #expect(button.tint == .remove)
    #expect(button.role == .destructive)
    #expect(button.accessibilityLabel == "Remove from Watch")
    #expect(button.hint == OnAppleWatchPresentation.removeSwipeHint)
  }

  @Test("rows are newest first and a copy removed on this iPhone is left out")
  func rowsOmitAPhoneRemovalAndKeepAWatchRemoval() {
    let copies = [
      copy(.delivered, id: 1, requestedAt: 30),
      copy(.removed, id: 2, removedBy: .phone, requestedAt: 20),
      copy(.removed, id: 3, removedBy: .watch, requestedAt: 10),
      copy(.sending, id: 4, requestedAt: 40),
      copy(.failed, id: 5, requestedAt: 50),
    ]

    let rows = OnAppleWatchPresentation.rows(copies, readiness: .canFetch)

    #expect(
      rows.map(\.id) == ["rss:1", "rss:3", "rss:4", "rss:5"],
      "a phone removal disappears; the Watch's tombstone and a failed download stay")
    #expect(rows.map(\.status) == [.onWatch, .removedOnWatch, .waitingForWatch, .couldNotDownload])
    #expect(rows.map(\.canRemove) == [true, false, true, true])
  }

  @Test("a row carries the model's artwork identity through to the screen")
  func rowsCarryTheResolvedArtwork() throws {
    let episode = try #require(
      RSSArtworkSource(
        feedID: 7, artworkURL: URL(string: "https://example.test/episode.jpg")!,
        feedURL: URL(string: "https://example.test/feed.xml")!))
    let show = try #require(
      RSSArtworkSource(
        feedID: 7, artworkURL: URL(string: "https://example.test/show.jpg")!,
        feedURL: URL(string: "https://example.test/feed.xml")!))

    let presented = OnAppleWatchPresentation.rows(
      [
        copy(
          .delivered, feedId: 7, artworkSource: .rss(episode),
          artworkFallbackSource: .rss(show))
      ],
      readiness: .canFetch)

    #expect(presented.count == 1)
    #expect(presented.first?.artworkItemID == "rss:7")
    #expect(presented.first?.artworkSource == ArtworkSource.rss(episode))
    #expect(presented.first?.artworkFallbackSource == ArtworkSource.rss(show))
  }

  @Test("storage is read-only from the last inventory and unknown until one arrives")
  func storageUsage() {
    #expect(
      OnAppleWatchPresentation.storageUsage(usedBytes: nil, totalBytes: nil)
        == "Not reported yet")
    #expect(
      OnAppleWatchPresentation.storageUsage(usedBytes: 0, totalBytes: 0)
        == "Not reported yet")
    let usage = OnAppleWatchPresentation.storageUsage(
      usedBytes: 500_000_000, totalBytes: 2_000_000_000)
    #expect(usage.contains(" of "))
    #expect(usage != "Not reported yet")
  }

  @Test("a missing Watch app hides the last inventory's storage figure rather than repeating it")
  func storageUsageWithoutAnInstalledWatchApp() {
    #expect(
      OnAppleWatchPresentation.storageUsage(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .notInstalled)
        == OnAppleWatchPresentation.storageNotReported)
    for readiness: WatchAppReadiness in [.unknown, .canFetch, .needsUpdate] {
      let usage = OnAppleWatchPresentation.storageUsage(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: readiness)
      #expect(usage.contains(" of "))
      #expect(usage != OnAppleWatchPresentation.storageNotReported)
    }
  }

  @Test("the storage summary is the figure alone, or says the Watch has not reported")
  func storageSummary() {
    #expect(
      OnAppleWatchPresentation.storageSummary(
        usedBytes: 0, totalBytes: 2_000_000_000, readiness: .canFetch)
        == "0 KB of 2 GB used")
    #expect(
      OnAppleWatchPresentation.storageSummary(
        usedBytes: nil, totalBytes: nil, readiness: .unknown)
        == "Watch storage not reported yet")
    #expect(
      OnAppleWatchPresentation.storageSummary(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .notInstalled)
        == "Watch storage not reported yet")
  }

  @Test("the storage bar fills to the reported fraction, clamped, and is absent until reported")
  func storageFraction() {
    #expect(
      OnAppleWatchPresentation.storageFraction(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .canFetch) == 0.25)
    #expect(
      OnAppleWatchPresentation.storageFraction(
        usedBytes: 3_000_000_000, totalBytes: 2_000_000_000, readiness: .canFetch) == 1)
    #expect(
      OnAppleWatchPresentation.storageFraction(
        usedBytes: nil, totalBytes: nil, readiness: .canFetch) == nil)
    #expect(
      OnAppleWatchPresentation.storageFraction(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .notInstalled) == nil)
  }

  @Test("free space is what the budget has left, never negative, and absent until reported")
  func storageFree() {
    #expect(
      OnAppleWatchPresentation.storageFree(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .canFetch)
        == "1.5 GB free")
    #expect(
      OnAppleWatchPresentation.storageFree(
        usedBytes: 3_000_000_000, totalBytes: 2_000_000_000, readiness: .canFetch)
        == "0 KB free")
    #expect(
      OnAppleWatchPresentation.storageFree(
        usedBytes: nil, totalBytes: nil, readiness: .canFetch) == nil)
    #expect(
      OnAppleWatchPresentation.storageFree(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .notInstalled) == nil)
  }

  @Test("VoiceOver hears the figure and the free space as one value")
  func storageAccessibilityValue() {
    #expect(
      OnAppleWatchPresentation.storageAccessibilityValue(
        usedBytes: 500_000_000, totalBytes: 2_000_000_000, readiness: .canFetch)
        == "500 MB of 2 GB used, 1.5 GB free")
    #expect(
      OnAppleWatchPresentation.storageAccessibilityValue(
        usedBytes: nil, totalBytes: nil, readiness: .unknown)
        == "Watch storage not reported yet")
  }

  @Test("the bar warns from nine tenths full and turns critical once nothing is left")
  func storageLevel() {
    #expect(OnAppleWatchPresentation.storageLevel(fraction: 0) == .normal)
    #expect(OnAppleWatchPresentation.storageLevel(fraction: 0.89) == .normal)
    #expect(OnAppleWatchPresentation.storageLevel(fraction: 0.9) == .nearlyFull)
    #expect(OnAppleWatchPresentation.storageLevel(fraction: 0.99) == .nearlyFull)
    #expect(OnAppleWatchPresentation.storageLevel(fraction: 1) == .full)
  }

  @Test("an empty Watch reads as a number, not ByteCountFormatter's \"Zero KB\"")
  func zeroBytesIsNumeric() {
    #expect(OnAppleWatchPresentation.bytes(0) == "0 KB")
  }

  @Test("the row mark draws only the states that give the row a Watch copy")
  func rowMarkMapping() {
    for state: WatchCopyState in [
      .wanted, .waitingForWatch, .sending,
    ] {
      #expect(PodcastShowViewPresentation.watchMark(for: state) == .sending)
    }
    #expect(PodcastShowViewPresentation.watchMark(for: .delivered) == .onWatch)
    let absent: [WatchCopyState] = [
      .removed(.phone), .removed(.watch), .declined(.storageFull), .failed(nil), .failed(.noAudio),
    ]
    for state in absent {
      #expect(PodcastShowViewPresentation.watchMark(for: state) == nil)
    }
    #expect(PodcastShowViewPresentation.watchMark(for: nil) == nil)
  }

  private func copy(
    _ state: RSSWatchCopyState,
    id: Int64 = 1,
    feedId: Int64 = 1,
    removedBy: RSSWatchCopyRemovalInitiator? = nil,
    declineReason: RSSWatchDeclineReason? = nil,
    download: WatchEpisodeDownloadStatus? = nil,
    artworkSource: ArtworkSource? = nil,
    artworkFallbackSource: ArtworkSource? = nil,
    requestedAt: TimeInterval = 10
  ) -> WatchEpisodeCopyRow {
    WatchEpisodeCopyRow(
      episodeId: id, feedId: feedId, identityKey: "episode-\(id)", title: "Episode \(id)",
      showTitle: "Show", artworkSource: artworkSource,
      artworkFallbackSource: artworkFallbackSource, state: state, removedBy: removedBy,
      declineReason: declineReason, downloadStatus: download,
      requestedAt: Date(timeIntervalSince1970: requestedAt))
  }
}
