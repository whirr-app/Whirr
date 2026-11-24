/// Derives a browse-sort key from a title. ABSApi's minified item projection has no "ignore
/// prefix" sort field, so this is a client-side `titleIgnorePrefix`: it strips a leading English
/// article.
///
/// Public because the server's alphabetical order is this key while native's is the raw feed
/// title; merging without a shared key would misorder an article-leading native show.
/// `PodcastsViewPresentation.mergedShowsPreview` uses it for both sides.
public enum ItemSortTitle {
  private static let ignoredPrefixes = ["the ", "a ", "an "]

  public static func derive(from title: String) -> String {
    let lowercased = title.lowercased()
    for prefix in ignoredPrefixes where lowercased.hasPrefix(prefix) {
      return String(title.dropFirst(prefix.count))
    }
    return title
  }
}
