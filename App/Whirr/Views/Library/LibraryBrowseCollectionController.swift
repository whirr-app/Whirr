import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import UIKit

struct LibraryBrowseHostedCellEnvironment: Equatable {
  var bookZoomTransitionContext: BookZoomTransitionContext?
  var bookZoomActiveSources: Set<BookZoomTransitionSource>
}

/// The root of every hosted cell. `transaction(value:)` stops a reconfigure (a reused cell taking
/// a new item) from animating: `CoverImageView` crossfades on `image != nil`, so a reused cell
/// whose new item is not yet prepared would fade the previous item's cover out inside it. A cold
/// completion that arrives later is a separate update and still fades in.
private struct LibraryBrowseHostedCell<Content: View>: View {
  let identity: LibraryBrowseCollectionItem
  let environment: LibraryBrowseHostedCellEnvironment
  let content: Content

  var body: some View {
    content
      .tint(AppChrome.tint)
      .environment(\.bookZoomTransitionContext, environment.bookZoomTransitionContext)
      .environment(\.bookZoomActiveSources, environment.bookZoomActiveSources)
      .transaction(value: identity) { $0.disablesAnimations = true }
  }
}

/// The UIKit side of `LibraryBrowseCollectionView`: owns the collection view, its diffable data
/// source and the scroll commands, and reports scroll phases back through the representable.
final class LibraryBrowseCollectionController: UIViewController, UICollectionViewDelegate {
  typealias DataSource = UICollectionViewDiffableDataSource<
    LibraryBrowseCollectionSection, LibraryBrowseCollectionItem
  >

  var tileContext: LibraryBrowseCollectionTileContext?
  var onRefresh: () async -> Void = {}
  var onScrollPhaseChange: (ScrollPhase) -> Void = { _ in }
  var controls = AnyView(EmptyView())
  var stateContent = AnyView(EmptyView())
  var scrollToTopRequest = 0
  var lastJumpSerial: Int?

  private var environment = LibraryBrowseHostedCellEnvironment(
    bookZoomTransitionContext: nil, bookZoomActiveSources: [])
  private var current: LibraryBrowseCollectionSnapshot?
  private var metricsByMode: [LibraryBrowsePresentation.Mode: LibraryBrowseCollectionMetrics] = [:]
  private var layoutInputs: LayoutInputs?
  private var pendingJumpTargetID: String?
  private var isMoving = false
  private var collectionView: UICollectionView!
  private var dataSource: DataSource!

  private struct LayoutInputs: Equatable {
    let availableWidth: CGFloat?
    let isAccessibilitySize: Bool
  }

  override func loadView() {
    let layout = LibraryBrowseCollectionLayout.make(
      sectionAt: { [weak self] index in self?.sectionIdentifier(at: index) },
      metrics: { [weak self] mode in self?.metrics(for: mode) ?? Self.fallbackMetrics(for: mode) })
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    // SwiftUI draws the editorial background behind the representable, so it follows the app's
    // appearance rules rather than a converted UIColor.
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .onDrag
    collectionView.allowsSelection = false
    collectionView.delegate = self
    collectionView.topEdgeEffect.style =
      PrimaryScrollEdgePresentation.style(for: .untitledRoot) == .hard
      ? UIScrollEdgeEffect.Style.hard : UIScrollEdgeEffect.Style.soft

    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)
    collectionView.refreshControl = refreshControl

    self.collectionView = collectionView
    dataSource = makeDataSource(collectionView)
    view = collectionView

    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
      (controller: LibraryBrowseCollectionController, _: UITraitCollection) in
      controller.updateLayoutInputs()
    }
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    updateLayoutInputs()
  }

  // MARK: Content

  func update(environment next: LibraryBrowseHostedCellEnvironment) {
    guard next != environment else { return }
    environment = next
    reconfigureVisible { _ in true }
  }

  /// Applies the next snapshot if it differs from the one on screen. Items whose identity survives
  /// but whose value changed are reconfigured in place. Controls and state refresh on every update
  /// because the root rebuilds their SwiftUI content each time.
  func apply(_ next: LibraryBrowseCollectionSnapshot, animation: Animation?) {
    let previous = current
    guard previous != next else {
      reconfigureVisible { $0 == .controls || $0 == .state || $0 == .banner }
      return
    }
    current = next

    var snapshot = NSDiffableDataSourceSnapshot<
      LibraryBrowseCollectionSection, LibraryBrowseCollectionItem
    >()
    for section in next.sections {
      snapshot.appendSections([section.id])
      snapshot.appendItems(section.items, toSection: section.id)
    }
    let present = Set(next.itemIdentifiers)
    var changed: [LibraryBrowseCollectionItem] = [.controls]
    if present.contains(.state) { changed.append(.state) }
    if present.contains(.banner) { changed.append(.banner) }
    if let previous {
      for (id, item) in next.titles where previous.titles[id].map({ $0 != item }) == true {
        changed.append(.title(id))
      }
      for (id, group) in next.groups where previous.groups[id].map({ $0 != group }) == true {
        changed.append(LibraryBrowseCollectionSnapshot.entityItem(id, in: next.mode))
      }
    }
    let previousItems = previous.map { Set($0.itemIdentifiers) } ?? []
    snapshot.reconfigureItems(changed.filter { present.contains($0) && previousItems.contains($0) })

    // A mode switch, or a filter the root applies inside `withAnimation`, settles with the same
    // opacity curve the root's transaction carries. A sync publish or a page arrives outside any
    // transaction and applies immediately.
    if let animation, previous != nil, viewIfLoaded?.window != nil,
      let outgoing = collectionView.snapshotView(afterScreenUpdates: false)
    {
      outgoing.frame = collectionView.frame
      outgoing.isUserInteractionEnabled = false
      collectionView.superview?.insertSubview(outgoing, aboveSubview: collectionView)
      dataSource.apply(snapshot, animatingDifferences: false)
      UIView.animate(animation) {
        outgoing.alpha = 0
      } completion: {
        outgoing.removeFromSuperview()
      }
    } else {
      dataSource.apply(snapshot, animatingDifferences: false)
    }
  }

  private func sectionIdentifier(at index: Int) -> LibraryBrowseCollectionSection? {
    let identifiers = dataSource.snapshot().sectionIdentifiers
    return identifiers.indices.contains(index) ? identifiers[index] : nil
  }

  private func reconfigureVisible(_ predicate: (LibraryBrowseCollectionItem) -> Bool) {
    guard let dataSource, current != nil else { return }
    let items = collectionView.indexPathsForVisibleItems
      .compactMap { dataSource.itemIdentifier(for: $0) }
      .filter(predicate)
    guard items.isEmpty == false else { return }
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems(items)
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  // MARK: Layout

  private func metrics(for mode: LibraryBrowsePresentation.Mode) -> LibraryBrowseCollectionMetrics {
    if let metrics = metricsByMode[mode] { return metrics }
    let inputs = layoutInputs ?? LayoutInputs(availableWidth: nil, isAccessibilitySize: false)
    let metrics = LibraryBrowseCollectionMetrics.resolve(
      for: mode,
      availableWidth: inputs.availableWidth,
      isAccessibilitySize: inputs.isAccessibilitySize)
    metricsByMode[mode] = metrics
    return metrics
  }

  private static func fallbackMetrics(
    for mode: LibraryBrowsePresentation.Mode
  ) -> LibraryBrowseCollectionMetrics {
    LibraryBrowseCollectionMetrics.resolve(
      for: mode, availableWidth: nil, isAccessibilitySize: false)
  }

  /// Split View panes resolve from their own width because this is the collection view's own.
  private func updateLayoutInputs() {
    guard let collectionView else { return }
    let inputs = LayoutInputs(
      availableWidth: LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: collectionView.bounds.width,
        safeAreaLeading: collectionView.safeAreaInsets.left,
        safeAreaTrailing: collectionView.safeAreaInsets.right),
      isAccessibilitySize: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
    guard inputs != layoutInputs else { return }
    layoutInputs = inputs
    metricsByMode = [:]
    collectionView.collectionViewLayout.invalidateLayout()
    // Tile widths are captured by each hosted tile, so a width change reconfigures what is on
    // screen; everything else picks the new width up when it is dequeued.
    reconfigureVisible { item in
      switch item {
      case .title, .author, .series: true
      case .controls, .banner, .state, .loadMore: false
      }
    }
  }

  // MARK: Cells

  private func makeDataSource(_ collectionView: UICollectionView) -> DataSource {
    let title = titleCellRegistration()
    let series = seriesCellRegistration()
    let author = authorCellRegistration()
    let controls = controlsCellRegistration()
    let state = stateCellRegistration()
    let banner = bannerCellRegistration()
    let loadMore = loadMoreCellRegistration()
    let header = letterHeaderRegistration()

    let dataSource = DataSource(collectionView: collectionView) { collectionView, indexPath, item in
      switch item {
      case .title: collectionView.dequeueConfiguredReusableCell(using: title, for: indexPath, item: item)
      case .series: collectionView.dequeueConfiguredReusableCell(using: series, for: indexPath, item: item)
      case .author: collectionView.dequeueConfiguredReusableCell(using: author, for: indexPath, item: item)
      case .controls: collectionView.dequeueConfiguredReusableCell(using: controls, for: indexPath, item: item)
      case .state: collectionView.dequeueConfiguredReusableCell(using: state, for: indexPath, item: item)
      case .banner: collectionView.dequeueConfiguredReusableCell(using: banner, for: indexPath, item: item)
      case .loadMore: collectionView.dequeueConfiguredReusableCell(using: loadMore, for: indexPath, item: item)
      }
    }
    dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
      collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
    return dataSource
  }

  private func titleCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      guard case .title(let id) = item, let summary = current?.titles[id], let tileContext
      else { return }
      host(item, in: cell) {
        LibraryTitleGridTile(
          item: summary,
          tileWidth: metrics(for: .titles).tileWidth,
          prefetchIndex: 0,
          orderedIDs: [],
          revisionsByID: [:],
          coverClient: tileContext.coverClient,
          downloadStatus: tileContext.downloadStatus,
          finishedStatus: tileContext.finishedStatus,
          actions: tileContext.actions,
          playback: tileContext.playback,
          artworkPrefetcher: tileContext.artworkPrefetcher,
          onSelect: { [weak self] in self?.tileContext?.onSelectTitle($0) },
          onPresentReader: { [weak self] in self?.tileContext?.onPresentReader($0, $1, $2) },
          onSearch: { [weak self] in self?.tileContext?.onSearch($0) },
          prefetchesOnAppear: false)
      }
    }
  }

  private func seriesCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      guard case .series(let id) = item, let group = current?.groups[id], let tileContext
      else { return }
      host(item, in: cell) {
        LibrarySeriesGridTile(
          group: group,
          tileWidth: metrics(for: .series).tileWidth,
          prefetchIndex: nil,
          orderedCoverIDs: [],
          revisionsByID: [:],
          coverClient: tileContext.coverClient,
          artworkPrefetcher: tileContext.artworkPrefetcher,
          onSelect: { [weak self] in self?.tileContext?.onSelectEntity($0) },
          prefetchesOnAppear: false)
      }
    }
  }

  private func authorCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      guard case .author(let id) = item, let group = current?.groups[id], let tileContext
      else { return }
      host(item, in: cell) {
        LibraryAuthorGridTile(
          group: group,
          tileWidth: metrics(for: .authors).tileWidth,
          coverClient: tileContext.coverClient,
          onSelect: { [weak self] in self?.tileContext?.onSelectEntity($0) })
      }
    }
  }

  private func controlsCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      host(item, in: cell) { self.controls }
    }
  }

  private func stateCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      host(item, in: cell) { stateContent }
    }
  }

  private func bannerCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      host(item, in: cell) {
        LibraryBrowseCollectionBanner(text: current?.banner ?? "")
      }
    }
  }

  private func loadMoreCellRegistration()
    -> UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem>
  {
    UICollectionView.CellRegistration<UICollectionViewCell, LibraryBrowseCollectionItem> {
      [unowned self] cell, _, item in
      host(item, in: cell) {
        LibraryBrowseCollectionLoadMore(mode: current?.mode ?? .authors)
      }
    }
  }

  private func letterHeaderRegistration() -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell> {
    UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
      elementKind: LibraryBrowseCollectionLayout.letterHeaderKind
    ) { [unowned self] cell, _, indexPath in
      guard let section = sectionIdentifier(at: indexPath.section),
        case .letter(_, let sectionID) = section
      else { return }
      cell.backgroundConfiguration = .clear()
      cell.contentConfiguration = UIHostingConfiguration {
        LibraryBrowseCollectionLetterHeader(sectionID: sectionID)
      }
      .margins(.all, 0)
    }
  }

  private func host<Content: View>(
    _ item: LibraryBrowseCollectionItem, in cell: UICollectionViewCell,
    @ViewBuilder content: () -> Content
  ) {
    cell.backgroundConfiguration = .clear()
    cell.contentConfiguration = UIHostingConfiguration {
      LibraryBrowseHostedCell(identity: item, environment: environment, content: content())
    }
    .margins(.all, 0)
  }

  // MARK: Delegate

  func collectionView(
    _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard let item = dataSource.itemIdentifier(for: indexPath), let current, let tileContext
    else { return }
    switch item {
    case .loadMore:
      tileContext.onLoadMore()
    case .title, .series:
      guard let index = current.prefetchIndices[item] else { return }
      tileContext.artworkPrefetcher.observe(
        visibleIndex: DirectionalArtworkPrefetcher.rowAlignedIndex(
          index, columns: metrics(for: current.mode).columns),
        orderedIDs: current.prefetchOrder,
        displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        displayScale: traitCollection.displayScale,
        client: tileContext.coverClient,
        revisionsByID: current.prefetchRevisions)
    case .author, .controls, .banner, .state:
      break
    }
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    send(.willBeginDragging)
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    send(.didEndDragging(willDecelerate: decelerate))
  }

  func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
    send(.willBeginDecelerating)
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    send(.didEndDecelerating)
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    send(.didEndScrollingAnimation)
    settlePendingJump()
  }

  /// A status-bar tap scrolls to the top without `didEndScrollingAnimation`. It is only announced
  /// as motion when there is somewhere to go, because an already-top list never reports arriving.
  func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
    if scrollView.contentOffset.y > topOffset + 0.5 { send(.beganAnimatedScroll) }
    return true
  }

  func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
    send(.didScrollToTop)
  }

  private func send(_ event: LibraryBrowseScrollEvent) {
    guard let phase = event.phase else { return }
    isMoving = phase != .idle
    onScrollPhaseChange(phase)
  }

  /// A host removed mid-fling never reports `.idle`; the root's `onDisappear` retires its own
  /// sources, and this covers a host dismantled while the root stays, as on entering selection.
  func retireScrollPhase() {
    guard isMoving else { return }
    send(.didEndDecelerating)
  }

  // MARK: Scroll commands

  /// The top edge including the search drawer and the rest of the adjusted inset, which a row
  /// anchor cannot reach.
  private var topOffset: CGFloat { -collectionView.adjustedContentInset.top }

  private var maximumOffset: CGFloat {
    max(
      topOffset,
      collectionView.contentSize.height - collectionView.bounds.height
        + collectionView.adjustedContentInset.bottom)
  }

  func scrollToTop(animated: Bool) {
    guard isViewLoaded else { return }
    scroll(to: topOffset, animated: animated)
  }

  func jump(to targetID: String, animated: Bool) {
    guard isViewLoaded, let current,
      let section = current.section(forTargetID: targetID),
      let sectionIndex = dataSource.snapshot().indexOfSection(section)
    else { return }
    collectionView.layoutIfNeeded()
    guard let offset = headerOffset(inSection: sectionIndex) else { return }
    pendingJumpTargetID = animated ? targetID : nil
    scroll(to: offset, animated: animated)
    if animated == false { settle(targetID: targetID) }
  }

  private func scroll(to y: CGFloat, animated: Bool) {
    let target = min(max(y, topOffset), maximumOffset)
    let moves = abs(collectionView.contentOffset.y - target) > 0.5
    // An animated scroll that goes nowhere never reports its end, so it is not announced.
    if animated, moves { send(.beganAnimatedScroll) }
    collectionView.setContentOffset(
      CGPoint(x: collectionView.contentOffset.x, y: target), animated: animated && moves)
  }

  private func headerOffset(inSection section: Int) -> CGFloat? {
    collectionView.layoutAttributesForSupplementaryElement(
      ofKind: LibraryBrowseCollectionLayout.letterHeaderKind,
      at: IndexPath(item: 0, section: section)
    ).map { $0.frame.minY + topOffset }
  }

  /// Estimated heights above a far letter resolve as the scroll passes them, so the header can
  /// finish a few points from where the jump aimed. One unanimated correction lands it.
  private func settlePendingJump() {
    guard let targetID = pendingJumpTargetID else { return }
    pendingJumpTargetID = nil
    settle(targetID: targetID)
  }

  private func settle(targetID: String) {
    guard let current, let section = current.section(forTargetID: targetID),
      let sectionIndex = dataSource.snapshot().indexOfSection(section)
    else { return }
    collectionView.layoutIfNeeded()
    guard let offset = headerOffset(inSection: sectionIndex) else { return }
    let target = min(max(offset, topOffset), maximumOffset)
    if abs(collectionView.contentOffset.y - target) > 1 {
      collectionView.setContentOffset(
        CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
    }
  }

  // MARK: Refresh

  @objc private func refresh(_ control: UIRefreshControl) {
    Task { [weak self, onRefresh] in
      await onRefresh()
      self?.collectionView.refreshControl?.endRefreshing()
    }
  }
}

private struct LibraryBrowseCollectionLetterHeader: View {
  let sectionID: String

  var body: some View {
    Text(sectionID)
      .font(WhirrTypeToken.caption.font.weight(.semibold))
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Header-to-grid spacing.
      .padding(.bottom, WhirrSpacing.small)
  }
}

private struct LibraryBrowseCollectionBanner: View {
  let text: String

  var body: some View {
    Text(text)
      .font(WhirrTypeToken.caption.font)
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WhirrSpacing.small)
  }
}

private struct LibraryBrowseCollectionLoadMore: View {
  let mode: LibraryBrowsePresentation.Mode

  var body: some View {
    ProgressView()
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityLabel(
        "Loading more \(noun)")
  }

  /// Only the entity modes page; the others are named so a new mode must choose its copy.
  private var noun: String {
    switch mode {
    case .authors: AuthorSeriesBrowseCopy.entityNoun(for: .author)
    case .series: AuthorSeriesBrowseCopy.entityNoun(for: .series)
    case .titles: "titles"
    case .collections: "collections"
    }
  }
}
