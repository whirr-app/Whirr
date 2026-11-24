import Testing

/// Placeholder case proving the WhirrTests target builds, runs, and is wired into CI.
@Suite("WhirrTests scaffolding")
struct WhirrTestsPlaceholder {
  @Test("target builds and runs")
  func targetBuildsAndRuns() {
    #expect(1 + 1 == 2)
  }
}
