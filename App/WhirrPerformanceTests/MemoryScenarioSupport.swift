import ABSApi
import Foundation
import UIKit
import XCTest

@testable import Whirr

/// Shared substrate for the automatable memory scenarios.
///
/// The only XCTest bundle, since `XCTMemoryMetric` needs an `XCTestCase`; behavioural tests stay
/// in swift-testing (`WhirrTests`).
class MemoryScenarioCase: XCTestCase {

  /// Physical footprint plus wall clock. `XCTMemoryMetric` reports the test host process,
  /// `Whirr.app`, so the figures include the whole app, not just the objects under test.
  static let metrics: [XCTMetric] = [XCTMemoryMetric(), XCTClockMetric()]

  /// Five runs, none discarded. Memory is noisy on a shared machine. Below the XCTest default to
  /// keep a full pass inside CI's 20-minute budget. Also used by cases that loop by hand, because
  /// `measure` cannot express what they need.
  static let iterationCount = 5

  static var options: XCTMeasureOptions {
    let options = XCTMeasureOptions()
    options.iterationCount = iterationCount
    return options
  }

  /// Clears the shared decoded tier. `XCTMemoryMetric` reports whole-process footprint, so artwork
  /// left behind by one case would be charged to whichever case runs next. Each scenario builds its
  /// own `PreparedArtworkCache`, so this only concerns the host process.
  override func setUp() {
    super.setUp()
    PreparedArtworkCache.shared.removeAll()
  }

  override func tearDown() {
    PreparedArtworkCache.shared.removeAll()
    super.tearDown()
  }
}

// MARK: - Direct footprint probe

/// `XCTMemoryMetric` has no settled footprint: `Memory Peak Physical` is a high-water mark and
/// `Memory Physical` is net growth, noise at this scale. This reads `phys_footprint` from
/// `task_vm_info` at a chosen instant, the figure jetsam kills on.
enum MemoryProbe {

  static func physicalFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
  }

  static func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_000_000)
  }

  /// Lets deferred releases run (autorelease pools, `NSCache` eviction, CoreAnimation backing store
  /// reclaim) before a footprint is read. Without it, a "settled" reading is taken one microsecond
  /// after the purge.
  static func settle(seconds: TimeInterval = 0.5) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      autoreleasepool {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      }
    }
  }
}

// MARK: - Fixtures

enum MemoryScenarioFixtures {

  static let accountScope = ArtworkAccountScope("https://performance.example.test")

  /// A JPEG large enough that decoding it costs real memory (about a 600×600 RGBA bitmap once
  /// prepared). A 4×4 fixture would measure noise.
  static let coverData: Data = {
    let size = CGSize(width: 600, height: 600)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor.systemIndigo.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.systemOrange.setFill()
      context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
    }
    return image.jpegData(compressionQuality: 0.9)!
  }()

  static func artworkKeys(count: Int, pixelWidth: Int = 396) -> [ArtworkKey] {
    (0..<count).map { index in
      ArtworkKey(
        accountScope: accountScope,
        itemID: "perf-item-\(index)",
        variant: .libraryThumbnail(pixelWidth: pixelWidth),
        revision: .unversioned)
    }
  }
}

/// A `CoverImageClient` that exists only to be non-`nil`: `NowPlayingMetadataAdapter.
/// loadArtworkIfNeeded` returns early on `nil`, so passing it measures an adapter that never
/// loads artwork. Scenarios also inject an `artworkImageLoader`, which bypasses the client, so no
/// request reaches the network.
enum StubCoverImageClientFactory {
  static func make() -> CoverImageClient {
    CoverImageClient(
      server: try! ABSServerConfig(url: URL(string: "https://performance.example.test")!),
      httpClient: StubCoverHTTPClient())
  }
}

private struct StubCoverHTTPClient: HTTPClienting {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "image/jpeg"],
      body: MemoryScenarioFixtures.coverData)
  }
}

/// Serves fixture bytes with no network and no disk, so a scenario measures the decode/cache path
/// rather than URLSession or the file system.
final class InMemoryArtworkFetcher: ArtworkDataFetching, @unchecked Sendable {
  private let data: Data
  private let lock = NSLock()
  private var fetchCount = 0

  init(data: Data = MemoryScenarioFixtures.coverData) {
    self.data = data
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return fetchCount
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    lock.lock()
    fetchCount += 1
    lock.unlock()
    return CoverImageResult(data: data, contentType: "image/jpeg")
  }
}
