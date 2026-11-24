import CoreSupport

#if DEBUG || PERF_INVESTIGATION

  import UIKit
  import os

  /// Checks whether a `List` cell still collapses every card's `.contextMenu` into one row-wide
  /// menu. SwiftUI installs one `UIContextMenuInteraction` per hosting view either way, so the
  /// audit asks its delegate for a configuration over each card: one distinct configuration for a
  /// shelf is the collapse, one per card is per-card ownership.
  ///
  /// Never presents a menu (the acceptance long-press test in `Scripts/acceptance/` covers that).
  /// Building a configuration perturbs the run, so it has its own switch and never runs during a
  /// measurement pass.
  @MainActor
  enum HarnessMenuAudit {
    private static let log = CoreLogging.logger(category: "harness")

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["WHIRR_MENU_AUDIT"] == "1" }

    static func report(_ label: String) {
      guard isEnabled else { return }
      guard let window = keyWindow() else {
        log.notice("WHIRR_MENU_AUDIT label=\(label, privacy: .public) error=no-window")
        return
      }

      reportShelfSpacing(label, in: window)

      var rowIndex = 0
      for cell in probeBands(in: window) {
        guard cell.bounds.width > 0, cell.bounds.height > 0 else { continue }
        var identifiers: [String] = []
        var owners = Set<ObjectIdentifier>()
        for column in 0..<8 {
          let fraction = 0.08 + 0.84 * (CGFloat(column) / 7.0)
          let local = CGPoint(x: cell.bounds.width * fraction, y: cell.bounds.midY)
          let inWindow = cell.convert(local, to: window)
          guard let hit = window.hitTest(inWindow, with: nil),
            let (owner, interaction) = nearestMenuOwner(from: hit)
          else {
            identifiers.append("none")
            continue
          }
          owners.insert(ObjectIdentifier(owner))
          let point = window.convert(inWindow, to: owner)
          let configuration = interaction.delegate?.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: point)
          identifiers.append(configuration.map { describe($0.identifier) } ?? "nil")
        }
        let resolved = identifiers.filter { $0 != "none" && $0 != "nil" }
        guard resolved.isEmpty == false else { continue }
        let ownerNames = owners.count
        log.notice(
          """
          WHIRR_MENU_AUDIT label=\(label, privacy: .public) row=\(rowIndex) \
          probed=\(identifiers.count) resolved=\(resolved.count) \
          distinct_menus=\(Set(resolved).count) owners=\(ownerNames) \
          ids=[\(identifiers.joined(separator: "|"), privacy: .public)]
          """)
        rowIndex += 1
      }
      log.notice("WHIRR_MENU_AUDIT label=\(label, privacy: .public) rows=\(rowIndex) done=1")
    }

    /// Reports where each shelf sits in the page, so two containers can be compared on the gaps
    /// between shelves rather than only on the page's total height.
    private static func reportShelfSpacing(_ label: String, in window: UIWindow) {
      guard let page = tallestScrollView(in: window) else { return }
      var shelves: [(CGFloat, CGFloat)] = []
      walk(page) { view in
        guard let scrollView = view as? UIScrollView, scrollView !== page else { return }
        guard scrollView.contentSize.width > scrollView.bounds.width else { return }
        let origin = scrollView.convert(scrollView.bounds.origin, to: page)
        shelves.append((origin.y, scrollView.bounds.height))
      }
      shelves.sort { $0.0 < $1.0 }
      var previousBottom: CGFloat?
      for (index, shelf) in shelves.enumerated() {
        let gap = previousBottom.map { shelf.0 - $0 } ?? -1
        log.notice(
          """
          WHIRR_SHELF_SPACING label=\(label, privacy: .public) index=\(index) \
          y=\(shelf.0, privacy: .public) h=\(shelf.1, privacy: .public) \
          gap_above=\(gap, privacy: .public)
          """)
        previousBottom = shelf.0 + shelf.1
      }
      log.notice(
        """
        WHIRR_SHELF_SPACING label=\(label, privacy: .public) shelves=\(shelves.count) \
        page_h=\(page.contentSize.height, privacy: .public)
        """)
    }

    // MARK: - Resolution

    private static func nearestMenuOwner(from view: UIView) -> (UIView, UIContextMenuInteraction)? {
      var current: UIView? = view
      while let candidate = current {
        if let interaction = candidate.interactions.compactMap({ $0 as? UIContextMenuInteraction })
          .first
        {
          return (candidate, interaction)
        }
        current = candidate.superview
      }
      return nil
    }

    /// A `UIContextMenuConfiguration`'s identifier is opaque. Two presses that resolve to the same
    /// card must produce equal identifiers, so its description is enough to count distinct menus.
    private static func describe(_ identifier: NSCopying) -> String {
      String(describing: identifier)
        .replacingOccurrences(of: " ", with: "")
        .suffix(24)
        .description
    }

    // MARK: - Hierarchy

    private static func keyWindow() -> UIWindow? {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
    }

    private static func cells(in root: UIView) -> [UIView] {
      var found: [UIView] = []
      walk(root) { view in
        let name = String(describing: type(of: view))
        if name.contains("CollectionViewCell") || name.contains("TableViewCell") {
          found.append(view)
        }
      }
      return found
    }

    /// List rows are cells; a `LazyVStack` has none. Where there are no cells the scroll view is
    /// sliced into horizontal bands so both containers answer the same ownership question.
    private static func probeBands(in window: UIWindow) -> [UIView] {
      let cells = cells(in: window)
      guard cells.isEmpty else { return cells }
      guard let scrollView = tallestScrollView(in: window) else { return [] }
      return (0..<10).map { index in
        let band = UIView(
          frame: CGRect(
            x: 0, y: scrollView.bounds.height * CGFloat(index) / 10,
            width: scrollView.bounds.width, height: scrollView.bounds.height / 10))
        scrollView.addSubview(band)
        band.isUserInteractionEnabled = false
        return band
      }
    }

    private static func tallestScrollView(in root: UIView) -> UIScrollView? {
      var best: UIScrollView?
      walk(root) { view in
        guard let scrollView = view as? UIScrollView else { return }
        if scrollView.contentSize.height > (best?.contentSize.height ?? 0) { best = scrollView }
      }
      return best
    }

    private static func walk(_ view: UIView, _ visit: (UIView) -> Void) {
      visit(view)
      for subview in view.subviews { walk(subview, visit) }
    }
  }

#endif
