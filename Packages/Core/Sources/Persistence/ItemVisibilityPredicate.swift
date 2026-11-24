/// The visibility rule shared by projections that read an item through its library: the item is not
/// soft-deleted, its library is not soft-deleted, and the library is selected.
///
/// Catalogue, browse, search, Home and smart-list projections interpolate this. Queries that
/// deliberately omit a clause keep raw SQL and say why: the player, item detail, download
/// destination, progress and bookmark reads may address a row an excluded library would hide.
enum ItemVisibilityPredicate {
  /// SQL expression for queries whose tables are named `item` and `library`.
  static let sql = """
    item.softDeleted = 0
    AND library.softDeleted = 0 AND library.isIncluded = 1
    """
}
