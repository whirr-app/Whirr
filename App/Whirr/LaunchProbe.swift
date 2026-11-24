import Foundation

#if PERF_INVESTIGATION
  import QuartzCore
  import os
#endif

/// Marks a point on the launch timeline, in milliseconds since the process started. Compiles to
/// nothing outside the `PERF_INVESTIGATION` build, and the label is never formed there.
@inline(__always)
nonisolated func launchMark(_ name: @autoclosure () -> String) {
  #if PERF_INVESTIGATION
    LaunchProbe.shared.mark(name())
  #endif
}

/// Times one synchronous launch step. A plain call outside the `PERF_INVESTIGATION` build.
@inline(__always)
nonisolated func launchSpan<Value>(_ name: @autoclosure () -> String, _ body: () throws -> Value) rethrows -> Value {
  #if PERF_INVESTIGATION
    let start = CACurrentMediaTime()
    defer { LaunchProbe.shared.span(name(), start: start, end: CACurrentMediaTime()) }
    return try body()
  #else
    return try body()
  #endif
}

/// Marks the commit of the render pass this is called from, which is the closest in-process
/// stand-in for "a frame reached the screen". Call from the first `onAppear`.
@inline(__always)
@MainActor
func launchMarkCommit(_ name: @autoclosure () -> String) {
  #if PERF_INVESTIGATION
    let label = name()
    CATransaction.setCompletionBlock { LaunchProbe.shared.mark(label) }
  #endif
}

#if PERF_INVESTIGATION
  /// Launch timeline for the measurement build only. Lines go to stderr and to
  /// `tmp/whirr-launch-probe.txt` in the app container once `populated` is marked, or after ten
  /// seconds if it never is. Nothing is transmitted and nothing identifying is recorded.
  nonisolated final class LaunchProbe: @unchecked Sendable {
    static let shared = LaunchProbe()
    static let finalMark = "populated"

    private let lock = NSLock()
    private var lines: [String] = []
    private var seen: Set<String> = []
    private var didFlush = false
    /// `CACurrentMediaTime()` at the moment the kernel started the process.
    private let processStart: CFTimeInterval
    private let isMainThreadStart: Bool

    private init() {
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      sysctl(&mib, 4, &info, &size, nil, 0)
      let started = info.kp_proc.p_starttime
      var now = timeval()
      gettimeofday(&now, nil)
      let age =
        Double(now.tv_sec - started.tv_sec) + Double(now.tv_usec - started.tv_usec) / 1_000_000
      processStart = CACurrentMediaTime() - age
      isMainThreadStart = Thread.isMainThread
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in flush(reason: "timeout") }
    }

    private func milliseconds(_ time: CFTimeInterval) -> String {
      String(format: "%.1f", (time - processStart) * 1_000)
    }

    /// Only the first mark of a name counts: views re-evaluate, launches happen once.
    func mark(_ name: String) {
      let now = CACurrentMediaTime()
      let thread = Thread.isMainThread ? "main" : "bg"
      lock.lock()
      let isNew = seen.insert(name).inserted
      if isNew { lines.append("WHIRRLAUNCH mark \(name) at=\(milliseconds(now)) thread=\(thread)") }
      lock.unlock()
      if isNew, name == Self.finalMark { flush(reason: "populated") }
    }

    func span(_ name: String, start: CFTimeInterval, end: CFTimeInterval) {
      let thread = Thread.isMainThread ? "main" : "bg"
      let duration = String(format: "%.1f", (end - start) * 1_000)
      lock.lock()
      lines.append("WHIRRLAUNCH span \(name) at=\(milliseconds(start)) dur=\(duration) thread=\(thread)")
      lock.unlock()
    }

    private func flush(reason: String) {
      lock.lock()
      guard !didFlush else {
        lock.unlock()
        return
      }
      didFlush = true
      let output = (lines + ["WHIRRLAUNCH end reason=\(reason)"]).joined(separator: "\n") + "\n"
      lock.unlock()
      FileHandle.standardError.write(Data(output.utf8))
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("whirr-launch-probe.txt")
      try? output.write(to: file, atomically: true, encoding: .utf8)
    }
  }
#endif
