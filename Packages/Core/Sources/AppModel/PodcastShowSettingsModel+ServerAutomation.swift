import Foundation
import Persistence
import SyncEngine

/// ADR 0017: editing a server show's automatic-download settings from Show Settings.
///
/// A write is online-only and explicit. The chosen value shows at once while the write and its
/// confirming refresh run with controls disabled; a failed or unconfirmed write restores the stored
/// value beside its message. One intent sends one field, so a change never overwrites another the
/// server holds (for example a custom schedule).
extension PodcastShowSettingsModel {
  public func setServerDownloadsNewEpisodes(_ enabled: Bool) async {
    await sendServerChange(PodcastAutomationSettingsRequest(autoDownloadEpisodes: enabled))
  }

  public func setServerSchedule(_ preset: PodcastAutomationSchedulePreset) async {
    await sendServerChange(PodcastAutomationSettingsRequest(autoDownloadSchedule: preset))
  }

  /// Whirr never sends `0` ("unlimited") for this limit.
  public func setServerNewEpisodeLimit(_ count: Int) async {
    guard count >= 1 else { return }
    await sendServerChange(PodcastAutomationSettingsRequest(maxNewEpisodesToDownload: count))
  }

  /// `0` keeps every episode.
  public func setServerKeepLimit(_ count: Int) async {
    guard count >= 0 else { return }
    await sendServerChange(PodcastAutomationSettingsRequest(maxEpisodesToKeep: count))
  }

  /// Read once on creation, and again after the server refuses a write. A followed feed reads it
  /// only once a single server copy of it exists (`requestServerCapabilityOnce`), so a feed with no
  /// server copy never asks. Until it resolves the read-only section shows.
  func loadServerCapability() {
    guard supportsFeedCredentials == false else { return }
    requestServerCapabilityOnce()
  }

  func requestServerCapabilityOnce() {
    guard hasRequestedServerCapability == false else { return }
    hasRequestedServerCapability = true
    Task { @MainActor [weak self] in await self?.reloadServerCapability() }
  }

  private func reloadServerCapability() async {
    let capability = await serverCapabilityReading.capability()
    serverCapability = capability
    refreshServerSection()
  }

  private func sendServerChange(_ change: PodcastAutomationSettingsRequest) async {
    // The write target is the server item: the show itself, or a followed feed's single server
    // copy. A feed's own id is never sent to the server.
    guard serverSettingsEditor != nil, isSavingServerSettings == false,
      let serverItemID = serverTargetItemID
    else { return }
    isSavingServerSettings = true
    serverSettingsMessage = nil
    serverChangeOverlay = change
    refreshServerSection()
    var keepsOverlay = false
    defer {
      isSavingServerSettings = false
      if keepsOverlay == false {
        serverChangeOverlay = nil
        refreshServerSection()
      }
    }

    let outcome = await automationSettingsWriting.update(
      itemID: serverItemID, change: change, confirmation: .refreshLocalRow)
    switch outcome {
    case .confirmed(_, let refresh):
      // The server's response carries the value, so it stays showing until the stored row reports.
      keepsOverlay = true
      serverSettingsMessage =
        refresh == .incomplete ? PodcastServerSettingsMessage.savedPendingRefresh : nil
    case .unconfirmed:
      serverSettingsMessage = PodcastServerSettingsMessage.unconfirmed
    case .forbidden, .notPermitted:
      serverSettingsMessage = PodcastServerSettingsMessage.accountCannotChange
      await reloadServerCapability()
    case .notFound:
      serverSettingsMessage = PodcastServerSettingsMessage.showMissing
    case .uncertain:
      serverSettingsMessage = PodcastServerSettingsMessage.unreachable
    case .accountChanged, .cancelled:
      serverSettingsMessage = nil
    case .invalidRequest, .rejected, .failed:
      serverSettingsMessage = PodcastServerSettingsMessage.notAccepted
    }
  }
}
