import Testing

@testable import Persistence

/// One visibility rule, shared by every projection that reads an item through its library. The
/// projection suites prove the filtering behaviour; this pins the SQL the constant contributes, so
/// an edit cannot quietly drop a clause from every query at once.
@Suite struct ItemVisibilityPredicateTests {
  @Test("the rule states all three clauses")
  func sqlStatesAllThreeClauses() {
    let clauses = ItemVisibilityPredicate.sql.split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")

    #expect(
      clauses == "item.softDeleted = 0 AND library.softDeleted = 0 AND library.isIncluded = 1")
  }
}
