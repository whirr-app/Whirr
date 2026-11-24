import Foundation
import Persistence
import PlayerCore
import ReaderCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite struct ReaderModelTests {
  // MARK: - Open and download

  @Test("open requests an EPUB download before opening the renderer")
  func openWithDownloadFirstSequencesDownloadThenOpen() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      itemID: itemID, stateReading: stateReading, downloads: downloads, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.availableNotDownloaded)
    await waitUntil { downloads.calls == [.requestEbookDownload(itemID: itemID)] }
    #expect(renderer.openedLocalFileURLs.isEmpty)

    let fileURL = URL(fileURLWithPath: "/tmp/book.epub")
    stateReading.push(.downloadedReady(fileURL: fileURL))
    await openTask.value

    #expect(renderer.openedLocalFileURLs == [fileURL])
    #expect(model.state == .reading)
  }

  @Test("preference and restore reads begin concurrently after a downloaded file is ready")
  func openStartsPreferenceAndRestoreReadsConcurrently() async {
    let saved = position(total: 0.4, href: "chapter-4")
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(
      restoreTarget: .position(saved), gateFetch: true)
    let preferences = TestReaderPreferencesStore(gateFetch: true)
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, preferences: preferences, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))

    let bothRequested = await waitUntil("both local open reads requested") {
      let preferenceRequested = await preferences.fetchWasRequested
      let progressRequested = await progress.fetchWasRequested
      return preferenceRequested && progressRequested
    }
    #expect(bothRequested)

    await preferences.releaseFetch()
    await progress.releaseFetch()
    await openTask.value

    #expect(model.state == .reading)
    #expect(renderer.goToPositions == [saved])
  }

  @Test("closing during concurrent open reads prevents renderer, tracker, and relay startup")
  func closeDuringConcurrentOpenReadsDoesNotResumeOpen() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(gateFetch: true)
    let preferences = TestReaderPreferencesStore(gateFetch: true)
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, preferences: preferences, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))

    let bothRequested = await waitUntil("both local open reads requested") {
      let preferenceRequested = await preferences.fetchWasRequested
      let progressRequested = await progress.fetchWasRequested
      return preferenceRequested && progressRequested
    }
    #expect(bothRequested)

    await model.close()
    await preferences.releaseFetch()
    await progress.releaseFetch()
    await openTask.value

    #expect(model.state != .reading)
    #expect(renderer.openedLocalFileURLs.isEmpty)
    #expect(renderer.submittedPreferences.isEmpty)
    #expect(await progress.writtenPositions.isEmpty)
  }

  @Test("a throwing restore read is swallowed and the book still opens")
  func restoreReadFailureDoesNotFailOpen() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(fetchError: .restore)
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(model.state == .reading)
    #expect(renderer.goToPositions.isEmpty)
    #expect(renderer.goToTotalProgressions.isEmpty)
  }

  @Test("a throwing preference read takes the existing recoverable open failure path")
  func preferenceReadFailureIsRecoverable() async {
    let stateReading = TestReaderStateReading()
    let preferences = TestReaderPreferencesStore(fetchError: .preferences)
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, preferences: preferences, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(model.state == .recoverableError)
    #expect(renderer.openedLocalFileURLs.isEmpty)
  }

  @Test("the open request carries the stored preferences and exact saved position")
  func openRequestCarriesStoredPreferencesAndSavedPosition() async throws {
    let saved = position(total: 0.4, href: "chapter-4", position: 9)
    let stored = ReaderPreferences(
      theme: .sepia, fontFamily: .serif, fontSizeStep: 2, readingMode: .scroll)
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .position(saved))
    let preferences = TestReaderPreferencesStore(value: stored)
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, preferences: preferences, renderer: renderer)

    await open(model, stateReading: stateReading)

    let request = try #require(renderer.openRequests.first)
    #expect(request.localFileURL == URL(fileURLWithPath: "/tmp/book.epub"))
    #expect(request.preferences == stored)
    #expect(request.initialLocation == .position(saved))
  }

  @Test("a progression-only saved target becomes a progression open location")
  func progressionOnlySavedTargetBecomesOpenLocation() async throws {
    let progress = TestReaderProgressAccess(restoreTarget: .totalProgression(0.63))
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(renderer.openRequests.first?.initialLocation == .totalProgression(0.63))
  }

  @Test("an explicit contents target outranks the saved target in the open request")
  func explicitContentsTargetOutranksSavedTargetInOpenRequest() async throws {
    let saved = position(total: 0.1, href: "chapter-1")
    let requested = position(total: 0.6, href: "chapter-5")
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .position(saved))
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    let openTask = Task { await model.open(initialTarget: .position(requested)) }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(renderer.openRequests.first?.initialLocation == .position(requested))
    renderer.emit(requested)
    await waitUntil { model.currentPosition == requested }
    await model.close()
    #expect(await progress.writtenPositions == [requested], "the tracker remains seeded with the saved target")
  }

  @Test("an absent saved and explicit target produces a nil initial location")
  func absentTargetsProduceNilInitialLocation() async throws {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(renderer.openRequests.first?.initialLocation == nil)
  }

  @Test("opening a fixed-layout book submits only the capability-adjusted preferences")
  func fixedLayoutOnlySubmitsChangedCapabilityPreferences() async throws {
    let stored = ReaderPreferences(theme: .sepia, readingMode: .scroll, reflowable: true)
    let stateReading = TestReaderStateReading()
    let preferences = TestReaderPreferencesStore(value: stored)
    let renderer = FakeEPUBRendering(publication: OpenedEPUBPublication(reflowable: false))
    let model = makeModel(
      stateReading: stateReading, preferences: preferences, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(renderer.openRequests.first?.preferences == stored)
    #expect(
      renderer.submittedPreferences == [
        ReaderPreferences(theme: .sepia, readingMode: .scroll, reflowable: false)
      ])
  }

  @Test("opening a reflowable book does not resubmit unchanged preferences")
  func reflowableOpenDoesNotSubmitUnchangedPreferences() async {
    let stored = ReaderPreferences(theme: .sepia, readingMode: .scroll, reflowable: true)
    let stateReading = TestReaderStateReading()
    let preferences = TestReaderPreferencesStore(value: stored)
    let renderer = FakeEPUBRendering(publication: OpenedEPUBPublication(reflowable: true))
    let model = makeModel(
      stateReading: stateReading, preferences: preferences, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(renderer.submittedPreferences.isEmpty)
  }

  @Test("a confirmation retries thrown navigation until it lands within the budget")
  func confirmationRetriesThrownNavigationUntilLanding() async throws {
    let target = position(total: 0.4, href: "chapter-4")
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .position(target))
    let renderer = FakeEPUBRendering()
    renderer.navigationFailureScript = [true, true]
    // Generous budget: this case lands on the third attempt, so it never waits the budget out.
    // It only needs three attempts, each preceded by the retry loop's 50 ms sleep, to beat it.
    // A tight 500 ms flakes when the full suite loads the machine.
    // `alwaysFailingConfirmationExhaustsBudget` exhausts its budget, so it keeps a short one.
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer)

    await open(model, stateReading: stateReading)

    #expect(model.state == .reading)
    #expect(renderer.goToPositions == [target, target, target])
  }

  @Test("an always-failing confirmation exhausts its budget and still reaches reading")
  func alwaysFailingConfirmationExhaustsBudget() async throws {
    let target = position(total: 0.4, href: "chapter-4")
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .position(target))
    let renderer = FakeEPUBRendering()
    renderer.alwaysFailNavigation = true
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      restoreBudget: .milliseconds(120))

    await open(model, stateReading: stateReading)

    #expect(model.state == .reading)
    #expect(renderer.goToPositions.count >= 2)
  }

  @Test("closing while open is in flight closes the late publication and never reaches reading")
  func closeDuringRendererOpenClosesLatePublication() async throws {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    renderer.waitsForOpenRelease = true
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await waitUntil { renderer.openRequests.count == 1 }

    await model.close()
    await renderer.releaseOpen()
    await openTask.value

    #expect(model.state != .reading)
    #expect(renderer.lifecycleState == .ready)
    #expect(renderer.closeCallCount == 2)
  }

  @Test("download failure becomes a recoverable reader error")
  func downloadFailureIsRecoverable() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let failure = TestReaderError.download
    downloads.stubNextCall(throwing: failure)
    let model = makeModel(stateReading: stateReading, downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.availableNotDownloaded)
    await openTask.value

    #expect(model.state == .recoverableError)
    #expect(model.canRetryDownload)
    #expect(model.errorMessage == ReaderCopy.downloadFailed)
  }

  /// A failed row must not be read as "not downloaded": re-requesting is suppressed by the failed
  /// row itself, which would leave a 0% bar with no error and no retry.
  @Test("an already-failed download row stops at a recoverable error, not a 0% bar")
  func failedDownloadRowIsRecoverable() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let model = makeModel(stateReading: stateReading, downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadFailed)
    await openTask.value

    #expect(model.state == .recoverableError)
    #expect(model.canRetryDownload)
    #expect(model.errorMessage == ReaderCopy.downloadFailed)
    #expect(downloads.calls.isEmpty)
  }

  /// "Try again" cannot work here: the app refused a file whose length/type/status disagreed with
  /// what the server reported, and every retry re-reads the same server-side metadata (for
  /// example EPUBs repacked in place, so the server's recorded size is stale). The retry
  /// affordance itself stays, since requesting again is right after a server-side library scan.
  @Test("a rejected download names the server-side mismatch instead of advising a retry")
  func rejectedDownloadRowGetsItsOwnCopy() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let model = makeModel(stateReading: stateReading, downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadRejected)
    await openTask.value

    #expect(model.state == .recoverableError)
    #expect(model.canRetryDownload)
    #expect(model.errorMessage == ReaderCopy.downloadRejected)
    #expect(model.errorMessage != ReaderCopy.downloadFailed)
    #expect(downloads.calls.isEmpty)
  }

  /// A retry must re-enter the observation loop `open()` has already returned from. Re-requesting
  /// alone is suppressed by the surviving failed row, and even a working retry would leave the
  /// reader on a bar nothing advances.
  @Test("retrying a failed download discards the dead row and re-enters the open loop")
  func retryDownloadPurgesTheDeadRowAndReopens() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      itemID: itemID, stateReading: stateReading, downloads: downloads, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadFailed)
    await openTask.value
    #expect(model.state == .recoverableError)

    let retryTask = Task { await model.retryDownload() }
    await stateReading.waitUntilSubscribed(count: 2)
    stateReading.push(.availableNotDownloaded)
    await waitUntil { downloads.calls.count == 2 }
    let fileURL = URL(fileURLWithPath: "/tmp/book.epub")
    stateReading.push(.downloadedReady(fileURL: fileURL))
    await retryTask.value

    #expect(
      downloads.calls == [
        .purgeEbookDownload(itemID: itemID, source: .readerEbook),
        .requestEbookDownload(itemID: itemID),
      ])
    #expect(renderer.openedLocalFileURLs == [fileURL])
    #expect(model.state == .reading)
  }

  /// The reason behind `.recoverableError` is remembered, not derived from current state, so it
  /// can latch: a retry that fails in transit must not keep telling the reader to rescan a server
  /// that is now fine.
  @Test("a retry that fails in transit stops blaming the server for the first rejection")
  func recoverableErrorReasonDoesNotLatchAcrossARetry() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let model = makeModel(stateReading: stateReading, downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadRejected)
    await openTask.value
    #expect(model.errorMessage == ReaderCopy.downloadRejected)

    let retryTask = Task { await model.retryDownload() }
    await stateReading.waitUntilSubscribed(count: 2)
    stateReading.push(.downloadFailed)
    await retryTask.value

    #expect(model.state == .recoverableError)
    #expect(model.errorMessage == ReaderCopy.downloadFailed)
  }

  /// A hold is not a failure: the reader says why the transfer is parked and keeps listening, so
  /// joining Wi-Fi (or resuming) opens the book without the reader being dismissed and re-entered.
  @Test("a download held for Wi-Fi explains itself and still opens when the hold clears")
  func waitingForWiFiExplainsItselfAndKeepsListening() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, downloads: downloads, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadHeld(reason: .waitingForWiFi, progress: 0.3))
    await waitUntil { model.state == .downloadHeld(reason: .waitingForWiFi) }

    #expect(model.errorMessage == ReaderCopy.downloadHeld(.waitingForWiFi))
    #expect(model.canRetryDownload == false)
    #expect(model.canResumeDownload == false)
    #expect(downloads.calls.isEmpty)

    let fileURL = URL(fileURLWithPath: "/tmp/book.epub")
    stateReading.push(.downloadedReady(fileURL: fileURL))
    await openTask.value

    #expect(model.state == .reading)
  }

  @Test("a paused download offers a resume that reaches the ebook row")
  func pausedDownloadOffersResume() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let model = makeModel(itemID: itemID, stateReading: stateReading, downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadHeld(reason: .paused, progress: 0.4))
    await waitUntil { model.state == .downloadHeld(reason: .paused) }

    #expect(model.canResumeDownload)
    await model.resumeDownload()
    #expect(downloads.calls == [.resumeEbookDownload(itemID: itemID)])

    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value
    #expect(model.state == .reading)
  }

  @Test("an authentication hold is explained but offers no resume the reader could honour")
  func authenticationHoldOffersNoResume() async {
    let stateReading = TestReaderStateReading()
    let model = makeModel(stateReading: stateReading)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadHeld(reason: .pausedAuth, progress: 0))
    await waitUntil { model.state == .downloadHeld(reason: .pausedAuth) }

    #expect(model.errorMessage == ReaderCopy.downloadHeld(.pausedAuth))
    #expect(model.canResumeDownload == false)
    #expect(model.canRetryDownload == false)

    openTask.cancel()
    stateReading.finish()
    await openTask.value
  }

  // MARK: - Unopenable and terminal states

  @Test("DRM protection is terminal and has no redownload action")
  func drmProtectedIsTerminal() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    renderer.nextOpenFailure = .drmProtected
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.state == .drmProtected)
    #expect(model.canRetryDownload == false)
    #expect(model.errorMessage == ReaderCopy.drmProtected)
  }

  @Test("fixed-layout publications open with reflow controls disabled")
  func fixedLayoutDisablesReflowControls() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: OpenedEPUBPublication(reflowable: false))
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.state == .reading)
    #expect(model.reflowControlsEnabled == false)
    #expect(renderer.submittedPreferences.count == 1)
  }

  @Test("unopenable publications offer redownload and demote the row")
  func unopenableOffersRedownloadAndDemotesRow() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let renderer = FakeEPUBRendering()
    renderer.nextOpenFailure = .unopenable
    let model = makeModel(
      stateReading: stateReading, downloads: downloads, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.state == .unopenable)
    #expect(model.canRetryDownload)
    #expect(model.errorMessage == ReaderCopy.unopenable)
    #expect(
      downloads.calls == [.purgeEbookDownload(itemID: "book-1", source: .readerEbook)])
  }

  @Test("advertised EPUB without an ebook file never reaches the renderer")
  func noEbookFileNeverOpens() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.advertisedButUnavailable)
    await openTask.value

    #expect(model.state == .unavailable)
    #expect(renderer.openedLocalFileURLs.isEmpty)
  }

  @Test("advertised but unavailable refreshes once, then downloads after the row heals")
  func advertisedButUnavailableRefreshesOnceThenRequestsDownloadAfterHealing() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let extras = FakeItemDetailExtrasAccess(result: Self.emptyExtras)
    let downloads = FakeDownloadIntents()
    let model = makeModel(
      itemID: itemID,
      stateReading: stateReading,
      extrasAccess: extras,
      downloads: downloads)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.advertisedButUnavailable)
    await waitUntil { extras.itemIDs == [itemID] && model.state == .unavailable }

    stateReading.push(.availableNotDownloaded)
    await waitUntil { downloads.calls == [.requestEbookDownload(itemID: itemID)] }
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(extras.itemIDs == [itemID])
    #expect(model.state == .reading)
  }

  @Test("a failed identity refresh ends with the advertised-but-unavailable copy")
  func extrasFetchFailureTerminatesAsAdvertisedButUnavailable() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let extras = FakeItemDetailExtrasAccess()
    let model = makeModel(itemID: itemID, stateReading: stateReading, extrasAccess: extras)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.advertisedButUnavailable)
    await openTask.value

    #expect(extras.itemIDs == [itemID])
    #expect(model.state == .unavailable)
    #expect(model.errorMessage == ReaderCopy.advertisedButUnavailable)
  }

  @Test("a second advertised-but-unavailable emission does not refresh again")
  func secondAdvertisedButUnavailableEmissionDoesNotRefreshAgain() async {
    let itemID = "book-1"
    let stateReading = TestReaderStateReading()
    let extras = FakeItemDetailExtrasAccess(result: Self.emptyExtras)
    let model = makeModel(itemID: itemID, stateReading: stateReading, extrasAccess: extras)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.advertisedButUnavailable)
    await waitUntil { extras.itemIDs == [itemID] }
    stateReading.push(.advertisedButUnavailable)
    await openTask.value

    #expect(extras.itemIDs == [itemID])
    #expect(model.state == .unavailable)
    #expect(model.errorMessage == ReaderCopy.advertisedButUnavailable)
  }

  @Test("identity refresh waits, while no EPUB is terminal without a fetch")
  func identityRefreshWaitsAndTerminalStatesDoNotRefresh() async {
    let stateReading = TestReaderStateReading()
    let extras = FakeItemDetailExtrasAccess(result: Self.emptyExtras)
    let model = makeModel(stateReading: stateReading, extrasAccess: extras)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.ebookIdentityNotFetched)
    await waitUntil {
      extras.itemIDs == ["book-1"]
        && model.state == .unavailable
        && model.errorMessage == ReaderCopy.ebookIdentityNotFetched
    }
    #expect(extras.itemIDs == ["book-1"])

    stateReading.push(.availableNotDownloaded)
    await waitUntil { model.state == .downloading(progress: 0) }
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    let terminalReading = TestReaderStateReading()
    let terminalExtras = FakeItemDetailExtrasAccess(result: Self.emptyExtras)
    let terminalModel = makeModel(stateReading: terminalReading, extrasAccess: terminalExtras)
    let terminalTask = Task { await terminalModel.open() }
    await terminalReading.waitUntilSubscribed()
    terminalReading.push(.noEpubAdvertised)
    await terminalTask.value

    #expect(terminalExtras.itemIDs.isEmpty)
    #expect(terminalModel.state == .unavailable)
    #expect(terminalModel.errorMessage == ReaderCopy.noEpub)
  }

  /// Finishing says nothing about where the file is: a finished book opens on the same terms as
  /// any other, at the position it was left at.
  @Test("a finished book opens rather than being refused")
  func finishedBookOpens() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(
      restoreTarget: .position(
        ReadingPosition(
          href: "Text/end.xhtml", progression: 1, totalProgression: 1, position: 400)))
    let model = makeModel(stateReading: stateReading, progress: progress)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(model.state == .reading)
  }

  // MARK: - Offline open and publication-server failure

  @Test("offline opening of a downloaded EPUB does not request a download")
  func offlineDownloadedOpenTouchesNoDownloadBoundary() async {
    let stateReading = TestReaderStateReading()
    let downloads = FakeDownloadIntents()
    let model = makeModel(stateReading: stateReading, downloads: downloads)
    await open(
      model, stateReading: stateReading,
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))

    #expect(downloads.calls.isEmpty)
    #expect(model.state == .reading)
  }

  @Test("publication-server failure is distinct from an unopenable file")
  func publicationServerFailureIsDistinct() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    renderer.nextOpenFailure = .serverFailure
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.state == .publicationServerFailure)
    #expect(model.canRetryDownload == false)
    #expect(model.errorMessage == ReaderCopy.publicationServerFailure)
  }
}
