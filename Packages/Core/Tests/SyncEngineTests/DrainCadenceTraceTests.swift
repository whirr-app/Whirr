import Foundation
import Testing

@testable import SyncEngine

/// The device-day cadence trace. The acceptance rule is numeric (ten consecutive intervals, each
/// within ±2 s of nominal), so the trace must emit a drain timestamp. These tests own the
/// arithmetic and record shape; the `NSLog` is DEBUG-only and untestable, as with
/// `ReaderTrace`/`SearchTrace`.
@Suite struct DrainCadenceTraceTests {

  // MARK: - The recorder's arithmetic

  @Test func theFirstDrainOfARunHasNoPrecedingIntervalToReport() {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)

    #expect(record.sincePreviousDrain == nil)
    #expect(record.nominal == 15)
  }

  @Test func aSecondDrainReportsTheElapsedIntervalSinceTheFirst() throws {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)
    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_014.6), condition: .normal)

    // `Date` arithmetic on a `TimeInterval` is not exact, and the trace renders to one decimal
    // place anyway, so asserting bit equality would pin a precision the record never claims.
    #expect(abs(try #require(record.sincePreviousDrain) - 14.6) < 0.001)
    #expect(record.nominal == 15)
  }

  /// The ±2 s rule is evaluated by the reader, not by the app. The trace states the observation
  /// and the target, and never editorialises about whether they agree.
  @Test func anIntervalOutsideTheToleranceIsReportedPlainlyRatherThanFlagged() {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)
    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_031), condition: .normal)

    #expect(record.sincePreviousDrain == 31)
    #expect(record.nominal == 15)
  }

  /// A degraded-condition change cancels the pending deadline and schedules a fresh one
  /// (`scheduleNextPeriodicDrain`). The interval that then fires was scheduled under the new
  /// nominal, so that is the number the record must carry. Reporting the condition at fire time
  /// against the old target would manufacture a spurious ±2 s violation on every transition.
  @Test func theRecordCarriesTheNominalThatWasActuallyScheduled() {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)
    recorder.scheduled(nominal: 60)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_060), condition: .lowPower)

    #expect(record.nominal == 60)
    #expect(record.sincePreviousDrain == 60)
    #expect(record.condition == .lowPower)
  }

  // MARK: - Interruption

  /// `firePeriodicDrain` guards on `.playing`, so periodic drains are suppressed while paused.
  /// The recorder must not keep its `previousDrainAt` across the gap, or it reports the whole
  /// wall stretch as the next interval (`since=55.7 nominal=15.0`, 40 s over and not a fault).
  /// Item switch, pause, and loss of observation all cause this. The first interval after an
  /// interruption is not a measurement of anything.
  @Test func theFirstDrainAfterAnInterruptionHasNoPrecedingIntervalToReport() {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)

    recorder.interrupted()

    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_055.7), condition: .normal)

    #expect(record.sincePreviousDrain == nil)
    #expect(record.nominal == 15)
  }

  /// Only the first interval is discarded. The series resumes measuring from the drain that
  /// restarted it, so an interruption costs one line of the ten, not the whole run.
  @Test func theSeriesResumesMeasuringFromTheDrainThatFollowedTheInterruption() throws {
    var recorder = DrainCadenceRecorder()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)
    recorder.interrupted()
    recorder.scheduled(nominal: 15)
    _ = recorder.fired(now: Date(timeIntervalSince1970: 1_055.7), condition: .normal)

    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_070.7), condition: .normal)

    #expect(abs(try #require(record.sincePreviousDrain) - 15) < 0.001)
  }

  /// An interruption arriving before any drain has fired must not resurrect a "first" that was
  /// already reported, nor two interruptions in a row report two discarded intervals.
  @Test func repeatedInterruptionsWithNoDrainBetweenThemDiscardOnlyOneInterval() throws {
    var recorder = DrainCadenceRecorder()
    recorder.interrupted()
    recorder.interrupted()
    recorder.scheduled(nominal: 15)
    #expect(
      recorder.fired(now: Date(timeIntervalSince1970: 1_000), condition: .normal)
        .sincePreviousDrain == nil)

    recorder.scheduled(nominal: 15)
    let record = recorder.fired(now: Date(timeIntervalSince1970: 1_015), condition: .normal)
    #expect(abs(try #require(record.sincePreviousDrain) - 15) < 0.001)
  }

  @Test func everyDegradedConditionIsDistinguishable() {
    #expect(
      DrainCadenceTrace.Condition(isLowPowerMode: false, isConstrainedOrCellular: false) == .normal)
    #expect(
      DrainCadenceTrace.Condition(isLowPowerMode: true, isConstrainedOrCellular: false) == .lowPower)
    #expect(
      DrainCadenceTrace.Condition(isLowPowerMode: false, isConstrainedOrCellular: true) == .cellular)
    #expect(
      DrainCadenceTrace.Condition(isLowPowerMode: true, isConstrainedOrCellular: true)
        == .lowPowerAndCellular)
  }

  // MARK: - The record's rendered shape

  @Test func theRenderedLineCarriesTheStreamPrefixAndTheThreeReadableFields() {
    let line = DrainCadenceTrace.line(
      DrainCadenceTrace.Record(sincePreviousDrain: 14.6, nominal: 15, condition: .normal))

    #expect(line == "WHIRRSYNC drain since=14.6 nominal=15.0 condition=normal")
  }

  @Test func theFirstDrainRendersNoIntervalRatherThanAZeroThatWouldReadAsAViolation() {
    let line = DrainCadenceTrace.line(
      DrainCadenceTrace.Record(sincePreviousDrain: nil, nominal: 15, condition: .normal))

    #expect(line == "WHIRRSYNC drain since=first nominal=15.0 condition=normal")
  }

  /// One decimal place matters: a ±2 s tolerance cannot be judged from a whole-second
  /// figure at the boundary, and more precision than the scheduler itself offers is noise.
  @Test func theIntervalIsRenderedToOneDecimalPlace() {
    let line = DrainCadenceTrace.line(
      DrainCadenceTrace.Record(sincePreviousDrain: 59.94, nominal: 60, condition: .lowPower))

    #expect(line.contains("since=59.9"))
  }

  /// SECURITY.md: retain no URL, token, item or session id, or payload artifact. The trace
  /// cannot carry one: its record type has no field that could hold an identifier, so this pins
  /// the shape rather than sanitising a value after the fact.
  @Test func theRecordHasNowhereToPutAnIdentifier() {
    let line = DrainCadenceTrace.line(
      DrainCadenceTrace.Record(sincePreviousDrain: 15, nominal: 15, condition: .normal))
    let fields = line.split(separator: " ").dropFirst(2).map { $0.split(separator: "=")[0] }

    #expect(Set(fields.map(String.init)) == ["since", "nominal", "condition"])
  }
}
