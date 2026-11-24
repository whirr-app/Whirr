import Foundation
import WatchPlayback
import WatchProtocol

/// What a finished task may hand the store (ADR 0020 Decisions 2–4): the hop chain first, then the
/// final response against the bytes that arrived, and only then the file. The feed's declared
/// length is not consulted — inserted ads change it.
extension WatchRSSDownloadDriver {
  func rssDidComplete(
    _ token: WatchRSSCallbackToken, completion: WatchRSSDownloadCompletion
  ) async {
    beginCallback()
    defer { endCallback() }
    if let store, let entry = await pendingEntry(for: token, store: store) {
      WatchRSSDiagnostics.log(
        "rss_complete", token.key, taskIdentifier: token.taskIdentifier,
        [
          "matched": "yes", "bytes": String(completion.measuredBytes ?? -1),
          "status": String(completion.statusCode ?? -1),
        ])
      await settle(entry, completion: completion, store: store)
    } else {
      // The entry left the store, or a higher revision replaced it, while the task was finishing.
      WatchRSSDiagnostics.log(
        "rss_complete", token.key, taskIdentifier: token.taskIdentifier, ["matched": "no"])
      adapter.discardStagedFile(completion.stagedFileURL)
    }
    release(token)
    scheduleReconcile()
  }

  func rssDidFail(_ token: WatchRSSCallbackToken, error: Error?) async {
    beginCallback()
    defer { endCallback() }
    release(token)
    WatchRSSDiagnostics.log("rss_fail", WatchRSSDiagnostics.failureFields(token, error))
    guard let error else { return }
    // A task the driver replaced, removed or abandoned was cancelled on purpose: its row already
    // says why, and the store refuses the late callback anyway.
    if let urlError = error as? URLError, urlError.code == .cancelled { return }
    guard let store, let entry = await pendingEntry(for: token, store: store) else { return }
    await fail(entry, .network, store: store)
    scheduleReconcile()
  }

  private func settle(
    _ entry: WatchReceivedEpisode, completion: WatchRSSDownloadCompletion,
    store: WatchReceivedEpisodeStore
  ) async {
    guard let stagedFileURL = completion.stagedFileURL, let measuredBytes = completion.measuredBytes
    else {
      // The session completed without handing over a file, which a non-2xx status normally causes.
      let refused = completion.statusCode.map { !(200...206).contains($0) } ?? false
      await fail(entry, refused ? .httpStatus : .invalidResponse, store: store)
      return
    }
    guard let requested = completion.requestedURL ?? entry.enclosureURL,
      WatchEnclosureRedirectCheck.evaluate(requested: requested, hops: completion.hops)
        == .accepted
    else {
      // A background session follows redirects itself, so this is the only place ADR 0004's rule
      // can run. Missing metrics count as a rejection.
      adapter.discardStagedFile(stagedFileURL)
      await fail(entry, .insecureRedirect, store: store)
      return
    }
    let verdict = WatchEnclosureResponseCheck.evaluate(
      statusCode: completion.statusCode ?? 0, receivedBytes: measuredBytes,
      contentLength: completion.expectedContentLength,
      contentRangeTotal: completion.contentRangeTotal)
    let acceptedBytes: Int64
    switch verdict {
    case .success(let bytes):
      acceptedBytes = bytes
    case .failure(let reason):
      adapter.discardStagedFile(stagedFileURL)
      await fail(entry, reason, store: store)
      return
    }
    do {
      // The store consumes the file in every outcome, so nothing is left to remove here.
      _ = try await store.commitDownloadedFile(
        selection: entry.selection, revision: entry.revision,
        temporaryFileURL: stagedFileURL, acceptedBytes: acceptedBytes)
    } catch {
      adapter.discardStagedFile(stagedFileURL)
      await fail(entry, .invalidResponse, store: store)
      return
    }
    await didChange()
  }
}
