import Foundation

/// The viewer's page arithmetic, apart from PDFKit so it can be tested without a document.
/// `lastViewedPage` is stored as PDFKit's zero-based page index.
nonisolated enum SupplementPageMemory {
  /// Where the viewer opens: the remembered page, clamped to a document that may have changed
  /// length since it was remembered, or the first page.
  static func initialPageIndex(lastViewedPage: Int?, pageCount: Int) -> Int {
    guard pageCount > 0, let lastViewedPage else { return 0 }
    return min(max(lastViewedPage, 0), pageCount - 1)
  }

  /// "12 of 48", one-based for the reader.
  static func indicator(pageIndex: Int, pageCount: Int) -> String {
    guard pageCount > 0 else { return "" }
    let page = min(max(pageIndex, 0), pageCount - 1) + 1
    return "\(page) of \(pageCount)"
  }
}

/// What a tapped link in a supplement may do. A PDF is untrusted server content (SECURITY.md):
/// links that stay inside the document are PDFKit's own and never reach here; one carrying a
/// URL is either refused outright or confirmed first, through the same policy as the EPUB reader.
enum SupplementLinkAction: Equatable, Sendable {
  case refuse
  case confirm(url: URL, displayedTarget: String)

  static func action(for url: URL) -> SupplementLinkAction {
    switch ReaderLinkPolicy.decision(for: url) {
    case .refuse:
      return .refuse
    case .promptThenOpen:
      return .confirm(url: url, displayedTarget: ReaderLinkPolicy.displayedTarget(for: url))
    }
  }
}

/// Coalesces the visible page into the device-local page memory. Scrolling a long PDF moves the
/// current page many times a second; only the page the reader settles on is written, and the
/// pending one is written at once when the viewer goes away.
@MainActor
final class SupplementPageWriter {
  private let delay: Duration
  private let write: @MainActor (Int) async -> Void
  private var pending: Int?
  private var lastWritten: Int?
  private var debounce: Task<Void, Never>?

  init(initialPage: Int?, delay: Duration = .milliseconds(600), write: @escaping @MainActor (Int) async -> Void) {
    self.delay = delay
    self.write = write
    lastWritten = initialPage
  }

  func noteVisible(pageIndex: Int) {
    debounce?.cancel()
    guard pageIndex != lastWritten else {
      pending = nil
      return
    }
    pending = pageIndex
    debounce = Task { [weak self, delay] in
      try? await Task.sleep(for: delay)
      guard Task.isCancelled == false else { return }
      await self?.writePending()
    }
  }

  /// Writes the page the reader is on now, without waiting out the debounce.
  func flush() async {
    debounce?.cancel()
    await writePending()
  }

  private func writePending() async {
    guard let page = pending else { return }
    pending = nil
    lastWritten = page
    await write(page)
  }
}
