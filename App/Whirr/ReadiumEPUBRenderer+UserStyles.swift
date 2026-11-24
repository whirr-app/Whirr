import Foundation
import WebKit

extension ReadiumEPUBRenderer {
  /// ReadiumCSS sets alignment on the root and makes `body`, `p` and `li` inherit it, so a wrapper
  /// the publication aligns in between wins: Hachette's retail template justifies `div.galley-rw`
  /// around every chapter, making "Left" do nothing. This gives paragraphs and list items the
  /// reader's value directly. The selectors carry ReadiumCSS's own guards, so the rule is inert
  /// while publisher styles are on or alignment is "Publisher default", and follows preference
  /// changes without Swift tracking. `:root:root` outranks Readium's rule whichever lands later.
  static let alignmentOverrideCSS = """
    :root:root[style*="readium-advanced-on"][style*="--USER__textAlign"] *:not(blockquote):not(figcaption) p,
    :root:root[style*="readium-advanced-on"][style*="--USER__textAlign"] li {
      text-align: var(--USER__textAlign) !important;
    }
    """

  /// Adds a stylesheet and nothing else: no script message handler is registered here (see the
  /// `setupUserScripts` delegate method for why that matters).
  static func installUserStyles(into userContentController: WKUserContentController) {
    // A JSON string literal is a valid JavaScript string literal, which keeps the CSS's quotes and
    // newlines out of the script's syntax.
    guard
      let data = try? JSONEncoder().encode(alignmentOverrideCSS),
      let cssLiteral = String(data: data, encoding: .utf8)
    else { return }
    let source = """
      (function () {
        var style = document.createElement('style');
        style.textContent = \(cssLiteral);
        (document.head || document.documentElement).appendChild(style);
      })();
      """
    userContentController.addUserScript(
      WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
  }
}
