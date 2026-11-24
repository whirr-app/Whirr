import Foundation
import PodcastFeeds
import Testing

@Suite("Feed value parsing")
struct FeedValueParsingTests {
  @Test("parses RSS date variants with exact instants")
  func pubDates() {
    let cases: [(String, TimeInterval)] = [
      ("Thu, 06 Aug 2026 22:02:11 +0000", 1_786_053_731),
      ("Thu, 6 Aug 2026 22:02:11 +0000", 1_786_053_731),
      ("13 Aug 2026 10:15:49 +0000", 1_786_616_149),
      ("Thu, 06 Aug 2026 22:02:11 EST", 1_786_071_731),
      ("Thu, 06 Aug 2026 22:02:11 EDT", 1_786_068_131),
      ("Thu, 06 Aug 2026 22:02 +0000", 1_786_053_720),
      ("Thu, 06 Aug 26 22:02:11 +0000", 1_786_053_731),
      ("Thu, 06 Aug 99 22:02:11 +0000", 933_976_931),
      ("Thu, 06 Aug 2026 22:02:11", 1_786_053_731),
    ]
    for (value, expected) in cases {
      #expect(FeedValueParsing.pubDate(value)?.timeIntervalSince1970 == expected)
    }
    #expect(FeedValueParsing.pubDate("2026-08-06T22:02:11Z")?.timeIntervalSince1970 == 1_786_053_731)
    let atomCases: [(String, TimeInterval)] = [
      ("2026-08-13T10:15:49Z", 1_786_616_149),
      ("2026-08-13T10:15:49+02:00", 1_786_608_949),
      ("2026-08-13T10:15:49.500Z", 1_786_616_149.5),
    ]
    for (value, expected) in atomCases {
      #expect(FeedValueParsing.pubDate(value)?.timeIntervalSince1970 == expected)
    }
    #expect(FeedValueParsing.pubDate("garbage") == nil)
    #expect(FeedValueParsing.pubDate("") == nil)
  }

  @Test("parses podcast durations and rejects invalid forms")
  func durations() {
    let cases: [(String, TimeInterval?)] = [
      ("788", 788), ("788.5", 788.5), ("45:12", 2_712), ("02:32:25", 9_145),
      ("3:53:07", 13_987), ("5:07", 307), (" 90:00 ", 5_400),
      ("", nil), ("-1", nil), ("1:-2", nil), ("1::5", nil), ("::5", nil),
      ("1:2:3:4", nil), ("1:abc", nil), (".5", nil),
    ]
    for (value, expected) in cases {
      #expect(FeedValueParsing.duration(value) == expected)
    }
  }
}
