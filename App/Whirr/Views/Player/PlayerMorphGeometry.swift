import ABSApi
import AppModel
import DesignSystem
import SwiftUI
import UIKit

/// Where the mini player is, for the collapse that folds the expanded player into it.
///
/// The shell owns one; the bar, its cover and the page's cover publish anchors to it through the
/// environment. The dismissal animator reads them once at morph start, so they can't be stale as
/// cached geometry-change values can be when Split View or a resize moves the bar mid-presentation.
/// Anchors are `UIView`s, not SwiftUI frames: a `UIViewRepresentable` inside
/// `tabViewBottomAccessory` reports the bar's real window frame, a matched-geometry source there
/// doesn't resolve.
@MainActor
@Observable
final class PlayerMorphGeometry {
  enum Role: CaseIterable, Hashable {
    /// The mini player's content: the panel's destination.
    case bar
    /// The cover in the bar, where the flying cover lands.
    case barCover
    /// The cover on the expanded page, where the flying cover starts.
    case pageCover
  }

  /// Everything the morph needs, in window coordinates.
  struct Snapshot: Equatable {
    let bar: CGRect
    let barCover: CGRect
    let barCoverKey: ArtworkKey?
    /// Where the cover's flight starts, or `nil` when the page's cover cannot be measured. The
    /// morph needs only the bar; without this it runs with no flight.
    let pageCover: CGRect?
    let pageCoverKey: ArtworkKey?
    /// The cover the bar is drawing, when it has drawn the one `barCoverKey` names. The prepared
    /// cache empties when the app is backgrounded, so the first open after that finds neither
    /// key in it; this is what the cover's flight is drawn from then.
    var barCoverImage: UIImage? = nil
    /// The page's cover as the bar prepared it ahead of the open, when it holds the one
    /// `pageCoverKey` names. The bar's own image is a thumbnail, visibly soft at the page's size;
    /// this is what lets the flight start sharp when the prepared cache has nothing.
    var warmedPageCoverImage: UIImage? = nil
    /// The cover the page is drawing, when it has drawn the one `pageCoverKey` names. The page
    /// goes on drawing the image it holds after the prepared cache has dropped it, so this is
    /// what a collapse's flight is drawn from then: the open's `barCoverImage`, the other way.
    var pageCoverImage: UIImage? = nil

    /// The bar is a capsule.
    var barCornerRadius: CGFloat { bar.height / 2 }

    /// Whether the two covers draw the same image, so a flight from one to the other cannot
    /// visibly change picture. The variants always differ (a 44 pt thumbnail against the page's
    /// high-fidelity rung), so whole keys are never compared; a provisional or older cover on
    /// either side differs in source or revision.
    var coversMatch: Bool {
      guard pageCover != nil, let barCoverKey, let pageCoverKey else { return false }
      return barCoverKey.source == pageCoverKey.source
        && barCoverKey.itemID == pageCoverKey.itemID
        && barCoverKey.revision == pageCoverKey.revision
    }
  }

  /// Set while a morph is landing on the bar, so the bar can blank its content underneath the
  /// arriving panel. Observed only by `playerMorphTarget()`; the anchors never read it.
  var isMorphTarget = false

  /// Set while a copy of the cover is flying from the page to the bar, so both real covers stay
  /// hidden under it. Observed only by `playerMorphHidesDuringCoverFlight()`.
  var isCoverInFlight = false

  /// Set while an open flies the cover, and released with an animation once it lands, so the page
  /// cover's shadow fades in after the cover is back rather than appearing with it in one frame.
  /// The flying copy draws no shadow. Observed only by `playerMorphCoverShadow(_:)`.
  var isCoverShadowHeld = false

  /// Set while the page is growing out of the bar, so its dismiss handle stays hidden until the
  /// open releases it. Observed only by `playerMorphHiddenWhileOpening()`.
  var isOpening = false

  /// Whether there is a bar to land on at all. The shell refreshes it on every body evaluation and
  /// it is read live at morph time; see `canLand(presentation:isAccessoryPresented:)`. A relay the
  /// shell has not configured never lands.
  @ObservationIgnored var canLand: () -> Bool = { false }

  /// The bar's content as the bar last drew it, without its cover, for the label the collapse
  /// carries on its panel. Written by `playerMorphBarLabel(_:)` and rendered only when a collapse
  /// starts; `nil` where nothing supplies one, and the bar is then revealed with the glass.
  @ObservationIgnored var barLabel: AnyView?

  @ObservationIgnored private var anchors: [Role: WeakAnchor] = [:]

  private struct WeakAnchor {
    weak var view: PlayerMorphAnchorView?
  }

  /// The rule behind `canLand`. Logout moves the shell to `.setup` and collapses with the ordinary
  /// slide, so at the animator it looks exactly like Close; without this check, whether it morphed
  /// would depend on whether the accessory had left the window yet. Nothing playing and a
  /// selection screen holding the bottom bar both take the accessory down.
  static func canLand(
    presentation: NavigationModel.Presentation, isAccessoryPresented: Bool
  ) -> Bool {
    presentation == .shell && isAccessoryPresented
  }

  func register(_ anchor: PlayerMorphAnchorView, as role: Role) {
    anchors[role] = WeakAnchor(view: anchor)
  }

  /// Drops `anchor` only if it is still the registered one, so an old view leaving its window
  /// cannot take a newer registration with it.
  func unregister(_ anchor: PlayerMorphAnchorView, as role: Role) {
    guard anchors[role]?.view === anchor else { return }
    anchors[role] = nil
  }

  /// `barLabel` drawn at the bar's size. A fresh rendering, not a snapshot of the bar: the bar sits
  /// inside the system's glass, which a snapshot would bring with it.
  func barLabelImage(size: CGSize, scale: CGFloat) -> UIImage? {
    guard let barLabel, size.width > 0, size.height > 0, scale > 0 else { return nil }
    let renderer = ImageRenderer(
      content: barLabel.frame(width: size.width, height: size.height))
    renderer.scale = scale
    return renderer.uiImage
  }

  /// The geometry for a morph starting now, or `nil` when the collapse must slide: nothing to land
  /// on, or the bar or its cover missing, windowless, empty, off screen, or in another window (the
  /// page's cover failing those drops only its flight). While a pull-down's slide is paused the
  /// page reports the slide's end position, a screen height too low, so read again once stopped.
  func snapshot() -> Snapshot? {
    guard canLand() else { return nil }
    guard
      let bar = anchors[.bar]?.view,
      let barCover = anchors[.barCover]?.view,
      let window = bar.window,
      barCover.window === window,
      let barFrame = Self.frame(of: bar, in: window),
      let barCoverFrame = Self.frame(of: barCover, in: window)
    else { return nil }

    let pageCover = anchors[.pageCover]?.view.flatMap {
      view -> (CGRect, ArtworkKey?, UIImage?)? in
      guard view.window === window, let frame = Self.frame(of: view, in: window) else {
        return nil
      }
      return (frame, view.coverKey, view.drawnCoverImage)
    }
    return Snapshot(
      bar: barFrame, barCover: barCoverFrame, barCoverKey: barCover.coverKey,
      pageCover: pageCover?.0, pageCoverKey: pageCover?.1,
      barCoverImage: barCover.drawnCoverImage,
      warmedPageCoverImage: pageCover?.1.flatMap { barCover.warmedPageCoverImage(for: $0) },
      pageCoverImage: pageCover?.2)
  }

  private static func frame(of anchor: UIView, in window: UIWindow) -> CGRect? {
    let frame = anchor.convert(anchor.bounds, to: nil)
    guard frame.isNull == false, frame.isInfinite == false, frame.isEmpty == false,
      frame.intersects(window.bounds)
    else { return nil }
    return frame
  }
}

/// The view each surface places behind the thing it measures. It draws nothing and takes no
/// touches; it exists to be asked for its window frame.
final class PlayerMorphAnchorView: UIView {
  private weak var geometry: PlayerMorphGeometry?
  private var role: PlayerMorphGeometry.Role?
  /// The finished cache key of the cover this anchor sits behind, for the flight's image and its
  /// mismatch guard. `nil` for the bar itself.
  private(set) var coverKey: ArtworkKey?
  /// What the cover in front of this anchor last drew. Held strongly: the anchor lives exactly as
  /// long as that cover does.
  private var drawnCover: DrawnArtwork?

  /// The page's cover, prepared ahead of an open by the bar this anchor sits in. Only the bar's
  /// cover anchor carries one.
  private var warmedPageCover: DrawnArtwork?

  /// The image the bar prepared for the page's cover, if it is the one `key` names.
  func warmedPageCoverImage(for key: ArtworkKey) -> UIImage? {
    warmedPageCover?.image(for: key)
  }

  /// The image the cover is drawing for `coverKey`, if it has drawn it.
  var drawnCoverImage: UIImage? {
    coverKey.flatMap { drawnCover?.image(for: $0) }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(
    geometry: PlayerMorphGeometry, role: PlayerMorphGeometry.Role, coverKey: ArtworkKey?,
    drawnCover: DrawnArtwork? = nil, warmedPageCover: DrawnArtwork? = nil
  ) {
    self.coverKey = coverKey
    self.drawnCover = drawnCover
    self.warmedPageCover = warmedPageCover
    if self.geometry !== geometry || self.role != role {
      if let previous = self.geometry, let previousRole = self.role {
        previous.unregister(self, as: previousRole)
      }
      self.geometry = geometry
      self.role = role
    }
    if window != nil {
      geometry.register(self, as: role)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard let geometry, let role else { return }
    if window != nil {
      geometry.register(self, as: role)
    } else {
      geometry.unregister(self, as: role)
    }
  }
}

private struct PlayerMorphAnchor: UIViewRepresentable {
  let geometry: PlayerMorphGeometry
  let role: PlayerMorphGeometry.Role
  let coverKey: ArtworkKey?
  let drawnCover: DrawnArtwork?
  let warmedPageCover: DrawnArtwork?

  func makeUIView(context: Context) -> PlayerMorphAnchorView {
    PlayerMorphAnchorView(frame: .zero)
  }

  func updateUIView(_ view: PlayerMorphAnchorView, context: Context) {
    view.configure(
      geometry: geometry, role: role, coverKey: coverKey, drawnCover: drawnCover,
      warmedPageCover: warmedPageCover)
  }
}

private struct PlayerMorphAnchorModifier: ViewModifier {
  let role: PlayerMorphGeometry.Role
  let drawnCover: DrawnArtwork?
  let warmedPageCover: DrawnArtwork?
  let coverKey: () -> ArtworkKey?
  @Environment(\.playerMorphGeometry) private var geometry

  func body(content: Content) -> some View {
    if let geometry {
      content.background {
        PlayerMorphAnchor(
          geometry: geometry, role: role, coverKey: coverKey(), drawnCover: drawnCover,
          warmedPageCover: warmedPageCover
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    } else {
      content
    }
  }
}

/// Blanks the bar's content while a morph lands on it. A modifier of its own, so the flag
/// is observed here and never in `MiniPlayerContainerView.body`, which reads a large slice of
/// playback state and would re-evaluate all of it.
private struct PlayerMorphTargetModifier: ViewModifier {
  @Environment(\.playerMorphGeometry) private var geometry

  func body(content: Content) -> some View {
    let isTarget = geometry?.isMorphTarget == true
    // A collapse carries a still copy of the bar with its title at the start of the line, so the
    // bar's own title is sent back there while it is blank and the two agree at the hand-off.
    return content.opacity(isTarget ? 0 : 1).environment(\.isMarqueeSuspended, isTarget)
  }
}

/// Hides a real cover while its copy is in flight.
private struct PlayerMorphCoverFlightModifier: ViewModifier {
  @Environment(\.playerMorphGeometry) private var geometry

  func body(content: Content) -> some View {
    content.opacity(geometry?.isCoverInFlight == true ? 0 : 1)
  }
}

/// The page cover's drop shadow, drawn clear while an open holds it back.
private struct PlayerMorphCoverShadowModifier: ViewModifier {
  let emphasis: ExpandedPlayerPresentation.ArtworkEmphasis
  @Environment(\.playerMorphGeometry) private var geometry

  func body(content: Content) -> some View {
    let isHeld = geometry?.isCoverShadowHeld == true
    return content.shadow(
      color: .black.opacity(isHeld ? 0 : emphasis.shadowOpacity), radius: emphasis.shadowRadius,
      y: emphasis.shadowOffsetY)
  }
}

/// Holds a view hidden while the page grows out of the bar.
private struct PlayerMorphOpeningModifier: ViewModifier {
  @Environment(\.playerMorphGeometry) private var geometry

  func body(content: Content) -> some View {
    content.opacity(geometry?.isOpening == true ? 0 : 1)
  }
}

/// Hands the relay the bar's label. The relay does not observe it, so writing it while this body
/// is evaluated invalidates nothing.
private struct PlayerMorphBarLabelModifier<Label: View>: ViewModifier {
  let label: Label
  @Environment(\.playerMorphGeometry) private var geometry
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  func body(content: Content) -> some View {
    // The renderer starts from a default environment; the text size is the one input from this
    // one that changes the label's layout.
    let current = AnyView(label.environment(\.dynamicTypeSize, dynamicTypeSize))
    geometry?.barLabel = current
    // Load-bearing: SwiftUI evaluates a modifier's body only when something reads its value, and
    // a body that returns `content` alone holds nothing to read, so the line above never ran.
    // The appearance action gives the value a reader, and writes the label once more itself.
    return content.onAppear { geometry?.barLabel = current }
  }
}

extension View {
  /// Supplies the copy of the bar's content that a collapse carries on its panel: the bar as it
  /// is drawn now, with nothing in the cover's slot. A no-op without a relay.
  func playerMorphBarLabel(_ label: some View) -> some View {
    modifier(PlayerMorphBarLabelModifier(label: label))
  }

  /// Keeps this view hidden until the open out of the bar releases it. A no-op without a relay.
  func playerMorphHiddenWhileOpening() -> some View {
    modifier(PlayerMorphOpeningModifier())
  }

  /// Marks the mini player's content as the surface a morph lands on. A no-op without a relay.
  func playerMorphTarget() -> some View {
    modifier(PlayerMorphTargetModifier())
  }

  /// Hides this cover while the morph flies a copy of it. A no-op without a relay.
  func playerMorphHidesDuringCoverFlight() -> some View {
    modifier(PlayerMorphCoverFlightModifier())
  }

  /// The page cover's drop shadow at `emphasis`, held back while an open lands. Without a relay it
  /// is the plain shadow.
  func playerMorphCoverShadow(_ emphasis: ExpandedPlayerPresentation.ArtworkEmphasis) -> some View {
    modifier(PlayerMorphCoverShadowModifier(emphasis: emphasis))
  }

  /// Publishes this view's window frame to the environment's `PlayerMorphGeometry` as `role`. A
  /// no-op without one, so previews, harnesses and tests that mount these surfaces alone are
  /// unchanged. `coverKey` is evaluated only when a relay is present. `drawnCover` is the record
  /// the cover behind this anchor writes what it draws to; `warmedPageCover` is where the bar
  /// holds the page's cover it prepared ahead of an open.
  func playerMorphAnchor(
    _ role: PlayerMorphGeometry.Role, drawnCover: DrawnArtwork? = nil,
    warmedPageCover: DrawnArtwork? = nil,
    coverKey: @escaping () -> ArtworkKey? = { nil }
  ) -> some View {
    modifier(
      PlayerMorphAnchorModifier(
        role: role, drawnCover: drawnCover, warmedPageCover: warmedPageCover, coverKey: coverKey))
  }
}

extension EnvironmentValues {
  /// The shell's morph relay. Set explicitly on the accessory's content and on the presented
  /// page: neither inherits the shell's environment (the accessory is a sibling of the content it
  /// is attached to, and the page is hosted by its own UIKit controller).
  @Entry var playerMorphGeometry: PlayerMorphGeometry? = nil
}
