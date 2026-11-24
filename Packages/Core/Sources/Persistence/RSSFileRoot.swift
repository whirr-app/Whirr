/// The root for RSS enclosure files. RSS files live under `<downloads root>/RSS/`, a sibling of
/// the per-account `<downloads root>/<accountId>/` directories, so account removal's file sweep
/// can never touch them.
public enum RSSFileRoot {
  public static let directoryName = "RSS"
}
