import PDFKit
import SwiftUI
import UIKit

/// PDFKit's `PDFView` over one local file URL, so no network code lives here and the document
/// never sees the server. In-document links navigate in place (PDFKit's own). A link carrying a
/// URL reaches `pdfViewWillClick(onLink:with:)`, whose default would open it at once; the
/// coordinator hands it to the SwiftUI host, which applies `SupplementLinkAction` and confirms
/// before anything leaves the app.
struct SupplementPDFView: UIViewRepresentable {
  let fileURL: URL
  let initialPageIndex: (_ pageCount: Int) -> Int
  /// The thumbnail strip for jumping, toggled by the page indicator.
  let showsThumbnails: Bool
  let onLoad: (_ pageCount: Int) -> Void
  /// The file exists but PDFKit cannot open it: corrupt, truncated, or password-protected.
  let onLoadFailure: () -> Void
  let onPageChange: (_ pageIndex: Int) -> Void
  let onExternalLink: (URL) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> SupplementPDFContainerView {
    let container = SupplementPDFContainerView()
    container.pdfView.delegate = context.coordinator
    context.coordinator.parent = self
    context.coordinator.observePageChanges(of: container.pdfView)
    load(into: container, coordinator: context.coordinator)
    return container
  }

  func updateUIView(_ container: SupplementPDFContainerView, context: Context) {
    context.coordinator.parent = self
    if context.coordinator.loadedURL != fileURL {
      load(into: container, coordinator: context.coordinator)
    }
    container.setThumbnailsVisible(showsThumbnails)
  }

  static func dismantleUIView(_ container: SupplementPDFContainerView, coordinator: Coordinator) {
    coordinator.stopObserving()
    container.pdfView.delegate = nil
  }

  /// The callbacks are deferred a turn: this runs inside a SwiftUI update, and they write state.
  private func load(into container: SupplementPDFContainerView, coordinator: Coordinator) {
    coordinator.loadedURL = fileURL
    guard let document = PDFDocument(url: fileURL), document.isLocked == false,
      document.pageCount > 0
    else {
      container.pdfView.document = nil
      Task { @MainActor [onLoadFailure] in onLoadFailure() }
      return
    }
    container.pdfView.document = document
    let index = initialPageIndex(document.pageCount)
    if index > 0, let page = document.page(at: index) {
      container.pdfView.go(to: page)
    }
    let pageCount = document.pageCount
    Task { @MainActor [onLoad] in onLoad(pageCount) }
  }

  final class Coordinator: NSObject, PDFViewDelegate {
    var parent: SupplementPDFView?
    var loadedURL: URL?
    private var pageObserver: NSObjectProtocol?

    func observePageChanges(of pdfView: PDFView) {
      pageObserver = NotificationCenter.default.addObserver(
        forName: .PDFViewPageChanged, object: pdfView, queue: .main
      ) { [weak self, weak pdfView] _ in
        MainActor.assumeIsolated {
          guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage
          else { return }
          self?.parent?.onPageChange(document.index(for: page))
        }
      }
    }

    func stopObserving() {
      if let pageObserver {
        NotificationCenter.default.removeObserver(pageObserver)
      }
      pageObserver = nil
    }

    /// Replaces PDFKit's default, which opens the URL immediately.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
      parent?.onExternalLink(url)
    }
  }
}

/// The PDF and its thumbnail strip, laid out by UIKit so the strip can share the PDF view's
/// document without SwiftUI holding a reference to either.
final class SupplementPDFContainerView: UIView {
  let pdfView = PDFView()
  private let thumbnails = PDFThumbnailView()
  private static let thumbnailStripHeight: CGFloat = 72

  override init(frame: CGRect) {
    super.init(frame: frame)
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.autoScales = true
    pdfView.backgroundColor = .systemGroupedBackground
    pdfView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(pdfView)

    thumbnails.pdfView = pdfView
    thumbnails.layoutMode = .horizontal
    thumbnails.thumbnailSize = CGSize(width: 40, height: 56)
    thumbnails.backgroundColor = .secondarySystemBackground
    thumbnails.translatesAutoresizingMaskIntoConstraints = false
    thumbnails.isHidden = true
    addSubview(thumbnails)

    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: topAnchor),
      pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
      thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor),
      thumbnails.trailingAnchor.constraint(equalTo: trailingAnchor),
      thumbnails.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
      thumbnails.heightAnchor.constraint(equalToConstant: Self.thumbnailStripHeight),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setThumbnailsVisible(_ isVisible: Bool) {
    guard thumbnails.isHidden == isVisible else { return }
    thumbnails.isHidden = isVisible == false
  }
}
