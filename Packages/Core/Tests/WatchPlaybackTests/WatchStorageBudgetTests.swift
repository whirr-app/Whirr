import Testing
import WatchPlayback

@Suite("Watch storage budget")
struct WatchStorageBudgetTests {
  @Test("a claim within the total succeeds and one beyond it changes nothing")
  func claimsRespectTheTotal() throws {
    let budget = WatchStorageBudget(totalBytes: 100)
    #expect(budget.claim(80, for: .audiobookshelf))
    #expect(budget.reservedBytes(for: .audiobookshelf) == 80)
    #expect(budget.claim(120, for: .audiobookshelf) == false)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 80)
    #expect(budget.usedBytes == 80)
  }

  @Test("lowering a reservation always succeeds, even when the ledger is already over")
  func releaseNeverFails() throws {
    let budget = WatchStorageBudget(totalBytes: 100)
    budget.record(150, for: .audiobookshelf)
    #expect(budget.usedBytes == 150)
    #expect(budget.claim(120, for: .audiobookshelf))
    #expect(budget.claim(90, for: .audiobookshelf))
    #expect(budget.claim(160, for: .audiobookshelf) == false)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 90)
  }

  @Test("two owners share one total")
  func ownersShareTheTotal() throws {
    let budget = WatchStorageBudget(totalBytes: 100)
    #expect(budget.claim(80, for: .audiobookshelf))
    #expect(budget.claim(30, for: .receivedEpisodes) == false)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == 0)
    #expect(budget.claim(20, for: .receivedEpisodes))
    #expect(budget.usedBytes == 100)
    #expect(budget.claim(81, for: .audiobookshelf) == false)
    #expect(budget.claim(60, for: .audiobookshelf))
    #expect(budget.usedBytes == 80)
  }

  @Test("negative reservations clamp to zero")
  func negativesClamp() throws {
    let budget = WatchStorageBudget(totalBytes: 100)
    budget.record(10, for: .audiobookshelf)
    #expect(budget.claim(-5, for: .audiobookshelf))
    #expect(budget.reservedBytes(for: .audiobookshelf) == 0)
    budget.record(-1, for: .receivedEpisodes)
    #expect(budget.usedBytes == 0)
  }

  @Test("concurrent claims never push the ledger past the total")
  func concurrentClaimsStayWithinTheTotal() async {
    let budget = WatchStorageBudget(totalBytes: 100)
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          let owner: WatchStorageBudget.Owner =
            index.isMultiple(of: 2) ? .audiobookshelf : .receivedEpisodes
          _ = budget.claim(60, for: owner)
        }
      }
    }
    // Each owner can hold 60, but the two together cannot: exactly one claim wins.
    #expect(budget.usedBytes == 60)
    #expect(budget.usedBytes <= budget.totalBytes)
  }
}
