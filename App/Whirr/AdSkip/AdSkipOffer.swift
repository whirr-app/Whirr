import AppModel
import DesignSystem
import SwiftUI

/// The one-time offer of Reduce Ads in the expanded player: shown where the receipt and the
/// analysis status show, for a downloaded episode analysis would cover, to a listener who has
/// never chosen either way.
enum AdSkipOfferPresentation {
  static let text = "Skip ads automatically?"
  static let acceptTitle = "Turn On"
  static let dismissLabel = "Not Now"
  /// Episode loads the offer is shown for before it stops on its own.
  nonisolated static let maximumShowings = 3

  struct Inputs: Equatable {
    var status: PlaybackAdAnalysisStatus
    var asset: AdSkipSettingsModel.Asset
    /// The setting's key exists on this device: the listener, here or on a synced device, has
    /// already chosen, so there is nothing to offer.
    var hasChosenSetting: Bool
    var isAnswered: Bool
    var showings: Int
    /// The loaded episode is the one the latest showing was counted for, so that showing does not
    /// end itself by being counted.
    var isCountedLoad: Bool
  }

  nonisolated static func shouldPresent(_ inputs: Inputs) -> Bool {
    guard inputs.status == .notEnabled, inputs.hasChosenSetting == false,
      inputs.isAnswered == false
    else { return false }
    guard inputs.showings < maximumShowings || inputs.isCountedLoad else { return false }
    return acceptance(for: inputs.asset) != nil
  }

  enum Acceptance: Equatable {
    /// The speech model is here or on its way: the setting can simply be turned on.
    case enable
    /// The model has to be downloaded, which needs the listener's consent first.
    case confirmDownload
  }

  /// Nil while the asset is unread or there is no recogniser: the offer could not be acted on.
  nonisolated static func acceptance(for asset: AdSkipSettingsModel.Asset) -> Acceptance? {
    switch asset {
    case .checking, .unavailable: nil
    case .installed, .downloading, .waitingForWiFi: .enable
    case .notInstalled, .failed: .confirmDownload
    }
  }

  @MainActor
  static func accept(on model: AdSkipSettingsModel, confirm: () -> Void) {
    switch acceptance(for: model.asset) {
    case .enable: model.setToggle(true)
    case .confirmDownload: confirm()
    case nil: break
    }
  }

  /// The asset is read again here, not when the prompt went up: `confirmDownload` from a running
  /// download cancels it and starts over.
  @MainActor
  static func confirmDownload(on model: AdSkipSettingsModel, allowingCellular: Bool) {
    switch acceptance(for: model.asset) {
    case .confirmDownload: model.confirmDownload(allowingCellular: allowingCellular)
    case .enable: model.setToggle(true)
    case nil: break
    }
  }
}

/// What the offer remembers. Device-local; neither key is in `ICloudSettingsSync.syncedKeys`.
@MainActor
final class AdSkipOfferStore {
  static let answeredKey = "adSkip.offer.answered"
  static let showingsKey = "adSkip.offer.showings"
  static let shared = AdSkipOfferStore(defaults: .standard)

  private let defaults: UserDefaults
  /// The load the latest showing was counted for. In memory, like the status announcement's: the
  /// player reopened on the same episode is the same showing, a relaunch is a new one.
  private var countedLoad: String?

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  var isAnswered: Bool { defaults.bool(forKey: Self.answeredKey) }
  var showings: Int { defaults.integer(forKey: Self.showingsKey) }
  /// Nothing registers a default for the setting, so the key is absent until someone chooses.
  var hasChosenSetting: Bool { defaults.object(forKey: AdSkipPreference.key) != nil }

  func isCounted(load: String) -> Bool { countedLoad == load }

  func markAnswered() {
    defaults.set(true, forKey: Self.answeredKey)
  }

  func noteShown(forLoad load: String) {
    guard countedLoad != load else { return }
    countedLoad = load
    defaults.set(showings + 1, forKey: Self.showingsKey)
  }
}

/// What the offer works against. Nil in the environment means the live setting; the UI harness
/// supplies its own so a player run never builds the real ad-skip composition.
struct AdSkipOfferDependencies {
  let settings: AdSkipSettingsModel
  let store: AdSkipOfferStore

  @MainActor static var live: AdSkipOfferDependencies {
    AdSkipOfferDependencies(settings: .shared, store: .shared)
  }
}

extension EnvironmentValues {
  @Entry var adSkipOfferDependencies: AdSkipOfferDependencies? = nil
}

/// The offer's place in `AdSkipReceiptOverlay`, built only while the loaded episode's status is
/// `.notEnabled`. It refreshes the settings model itself: nothing else does outside Settings, and
/// a listener who has never opened Settings is who the offer is for.
struct AdSkipOfferSlot: View {
  let playback: PlaybackModel

  @Environment(\.adSkipOfferDependencies) private var injected
  @State private var isAnswered = false
  @State private var isConfirmingDownload = false

  private var load: String { "\(playback.loadedItemID ?? "")/\(playback.loadedEpisodeID ?? "")" }

  var body: some View {
    let dependencies = injected ?? .live
    let isPresented = AdSkipOfferPresentation.shouldPresent(
      .init(
        status: playback.adAnalysisStatus, asset: dependencies.settings.asset,
        hasChosenSetting: dependencies.store.hasChosenSetting,
        isAnswered: isAnswered || dependencies.store.isAnswered,
        showings: dependencies.store.showings,
        isCountedLoad: dependencies.store.isCounted(load: load)))
    ZStack {
      if isPresented {
        AdSkipOfferCapsule(
          onAccept: {
            AdSkipOfferPresentation.accept(on: dependencies.settings) {
              isConfirmingDownload = true
            }
          },
          onDismiss: {
            dependencies.store.markAnswered()
            isAnswered = true
          })
      }
    }
    .adSkipDownloadConfirmation(isPresented: $isConfirmingDownload) { allowingCellular in
      AdSkipOfferPresentation.confirmDownload(
        on: dependencies.settings, allowingCellular: allowingCellular)
    }
    .task(id: load) { await dependencies.settings.refresh() }
    .onChange(of: isPresented, initial: true) { _, presented in
      if presented { dependencies.store.noteShown(forLoad: load) }
    }
  }
}

/// The same glass as the receipt and the status line. Unlike the receipt, Close is always there:
/// declining is one of the offer's two answers, not an accessibility affordance.
struct AdSkipOfferCapsule: View {
  let onAccept: () -> Void
  let onDismiss: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        // Text, Turn On and Close do not fit two lines at these sizes.
        GlassContainer(in: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          VStack(spacing: 0) {
            label
              .padding(.horizontal, 18)
              .padding(.top, 10)
            HStack(spacing: 0) {
              acceptButton
              dismissButton
            }
          }
          .buttonStyle(.plain)
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
      } else {
        GlassContainer(in: Capsule()) {
          HStack(spacing: 0) {
            label
              .padding(.leading, 18)
              .padding(.trailing, 4)
              .frame(minHeight: 44)
            acceptButton
            dismissButton
          }
          .buttonStyle(.plain)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(PlayerAccessibilityID.adSkipOffer)
  }

  private var label: some View {
    Text(AdSkipOfferPresentation.text)
      .font(WhirrTypeToken.subheadline.font)
      .lineLimit(2)
      .multilineTextAlignment(.center)
  }

  private var acceptButton: some View {
    Button(action: onAccept) {
      Text(AdSkipOfferPresentation.acceptTitle)
        .font(WhirrTypeToken.subheadline.font.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(PlayerAccessibilityID.adSkipOfferAccept)
  }

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(WhirrTypeToken.caption.font.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(AdSkipOfferPresentation.dismissLabel)
    .accessibilityIdentifier(PlayerAccessibilityID.adSkipOfferDismiss)
  }
}
