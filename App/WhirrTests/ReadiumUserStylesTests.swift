import Foundation
import Testing
import WebKit

@testable import Whirr

/// Runs Readium's own `ReadiumCSS-after.css` in a real web view, because the defect lives in how
/// its cascade meets publication CSS: a string check on the injected rule could not show that.
///
/// Serialized because the cases share one web view: each web view starts its own content process,
/// which costs about two seconds, and every case only needs a fresh document.
@MainActor
@Suite(.serialized) struct ReadiumUserStylesTests {

  // Hachette's retail template (seen in The Faith of Beasts): body > div.galley-rw > section > p,
  // with the justification on the wrapper rather than on the paragraphs.
  private static let publisherCSS = ".galley-rw { text-align: justify; } .ragged { text-align: left; }"
  private static let chapterBody = """
    <div class="galley-rw"><section><h1 id="heading" style="text-align: center">One</h1>\
    <p id="justifiedWrapper">From the archive entry of the regulator-librarian.</p></section></div>\
    <div class="ragged"><p id="raggedWrapper">A paragraph in a left-aligned wrapper.</p></div>
    """

  @Test func leftAlignmentReachesParagraphsInsideAJustifiedWrapper() async throws {
    let page = try await renderedChapter(
      rootStyle: "--USER__advancedSettings: readium-advanced-on; --USER__textAlign: start;")

    #expect(try await page.textAlign(of: "justifiedWrapper") == "start")
    #expect(try await page.textAlign(of: "raggedWrapper") == "start")
  }

  @Test func justifyReachesParagraphsInsideALeftAlignedWrapper() async throws {
    let page = try await renderedChapter(
      rootStyle: "--USER__advancedSettings: readium-advanced-on; --USER__textAlign: justify;")

    #expect(try await page.textAlign(of: "justifiedWrapper") == "justify")
    #expect(try await page.textAlign(of: "raggedWrapper") == "justify")
  }

  @Test func headingsKeepThePublishersAlignment() async throws {
    let page = try await renderedChapter(
      rootStyle: "--USER__advancedSettings: readium-advanced-on; --USER__textAlign: start;")

    #expect(try await page.textAlign(of: "heading") == "center")
  }

  @Test func publisherAlignmentStandsWhileTheReaderHasNotChosenOne() async throws {
    // Publisher styles on: Readium never sets the advanced flag.
    let publisherStyles = try await renderedChapter(rootStyle: "--USER__textAlign: start;")
    #expect(try await publisherStyles.textAlign(of: "justifiedWrapper") == "justify")

    // Publisher styles off, alignment left at "Publisher default": no --USER__textAlign.
    let noAlignment = try await renderedChapter(rootStyle: "--USER__advancedSettings: readium-advanced-on;")
    #expect(try await noAlignment.textAlign(of: "justifiedWrapper") == "justify")
    #expect(try await noAlignment.textAlign(of: "raggedWrapper") == "left")
  }

  // MARK: - Harness

  private func renderedChapter(rootStyle: String) async throws -> RenderedPage {
    let bundle = try #require(
      Bundle.main.url(forResource: "Readium_ReadiumNavigator", withExtension: "bundle").flatMap(Bundle.init(url:)),
      "Readium's navigator resource bundle is not in the test host"
    )
    let readiumAfterURL = try #require(
      bundle.url(forResource: "ReadiumCSS-after", withExtension: "css", subdirectory: "Assets/Static/readium-css")
    )
    let readiumAfter = try String(contentsOf: readiumAfterURL, encoding: .utf8)

    // Readium serves the publication's stylesheet first and appends its own after it, and writes
    // the reader's settings into the root element's style attribute; this mirrors that order.
    let html = """
      <!DOCTYPE html><html style="\(rootStyle)"><head>
      <style>\(Self.publisherCSS)</style>
      <style>\(readiumAfter)</style>
      </head><body>\(Self.chapterBody)</body></html>
      """

    let webView = Self.sharedWebView
    let loader = NavigationWaiter()
    webView.navigationDelegate = loader
    try await loader.load(html, into: webView)
    return RenderedPage(webView: webView, loader: loader)
  }

  private static let sharedWebView: WKWebView = {
    let userContentController = WKUserContentController()
    ReadiumEPUBRenderer.installUserStyles(into: userContentController)
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    return WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: configuration)
  }()
}

@MainActor
private struct RenderedPage {
  let webView: WKWebView
  let loader: NavigationWaiter

  func textAlign(of id: String) async throws -> String {
    let value = try await webView.evaluateJavaScript(
      "getComputedStyle(document.getElementById('\(id)')).textAlign")
    return try #require(value as? String)
  }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, any Error>?

  func load(_ html: String, into webView: WKWebView) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      webView.loadHTMLString(html, baseURL: nil)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
  ) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
