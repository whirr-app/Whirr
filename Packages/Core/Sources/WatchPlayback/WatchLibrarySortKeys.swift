import Foundation

extension WatchLibraryItem {
  var sortTitle: String {
    let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let lower = raw.lowercased()
    for article in ["the ", "a ", "an "] where lower.hasPrefix(article) { return String(raw.dropFirst(article.count)) }
    return raw
  }

  var authorSortKey: String { author?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
}

extension WatchPodcastShow {
  var sortTitle: String {
    let lower = title.lowercased()
    for article in ["the ", "a ", "an "] where lower.hasPrefix(article) {
      return String(title.dropFirst(article.count))
    }
    return title
  }
}
