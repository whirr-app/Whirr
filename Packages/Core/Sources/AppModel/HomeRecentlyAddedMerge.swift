import Persistence

/// Pure policy for the Home Recently Added shelf. The native-preferred projection replaces the
/// ordinary ABS projection only while native subscriptions are enabled.
public enum HomeRecentlyAddedMerge {
  public static func select(
    snapshot: HomeRecentlyAddedSnapshot,
    nativeSubscriptionsEnabled: Bool
  ) -> [HomeItem] {
    nativeSubscriptionsEnabled ? snapshot.nativePreferred : snapshot.all
  }
}
