import SwiftUI

public enum MarqueePassPhase: Sendable, Equatable {
  case atStart
  case travelling
  case atEnd
}

public struct MarqueePassStep: Sendable, Equatable {
  public let phase: MarqueePassPhase
  public let offset: CGFloat
  public let duration: Double
  public let animated: Bool

  public init(phase: MarqueePassPhase, offset: CGFloat, duration: Double, animated: Bool) {
    self.phase = phase
    self.offset = offset
    self.duration = duration
    self.animated = animated
  }
}

/// Pure layout and timing decisions for a single-line marquee.
public struct MarqueeTextGeometry: Sendable, Equatable {
  private static let overflowEpsilon: CGFloat = 0.5

  /// Pause at either end of the line before it travels the other way. Long enough that the text is
  /// readable at rest for most of each cycle, and that the reversal reads as a deliberate return
  /// rather than a twitch.
  public static let dwellSeconds: Double = 2
  public static let defaultPointsPerSecond: CGFloat = 30
  public static let minimumTravelSeconds: Double = 0.5
  /// The default fade width before capping it for small columns.
  public static let defaultEdgeFadeWidth: CGFloat = 20

  /// The width of the fade at one edge of an overflowing line. Keeping this per-edge lets a
  /// future offset animation give the leading and trailing edges different widths. Unresolved or
  /// non-positive widths do not produce a fade, and a narrow column never becomes all fade.
  public static func edgeFadeWidth(
    overflow: CGFloat,
    availableWidth: CGFloat
  ) -> CGFloat {
    guard
      overflow.isFinite,
      availableWidth.isFinite,
      overflow > overflowEpsilon,
      availableWidth > 0
    else {
      return 0
    }

    return min(defaultEdgeFadeWidth, availableWidth / 3)
  }

  /// Whether the measured line should use the visual overflow treatment. Accessibility sizes
  /// remain a plain wrapped block, and unresolved measurements must not flash a
  /// fade while layout is still settling. This is a visual decision, so it does not inspect the
  /// Reduce Motion setting.
  public static func isOverflowing(
    contentWidth: CGFloat,
    availableWidth: CGFloat,
    isAccessibilitySize: Bool = false
  ) -> Bool {
    guard
      isAccessibilitySize == false,
      contentWidth.isFinite,
      availableWidth.isFinite,
      contentWidth > 0,
      availableWidth > 0
    else {
      return false
    }

    return contentWidth - availableWidth > overflowEpsilon
  }

  public static func shouldScroll(
    contentWidth: CGFloat,
    availableWidth: CGFloat,
    reduceMotion: Bool,
    isAccessibilitySize: Bool = false,
    isSuspended: Bool = false
  ) -> Bool {
    guard
      isSuspended == false,
      isAccessibilitySize == false,
      reduceMotion == false,
      contentWidth.isFinite,
      availableWidth.isFinite,
      availableWidth > 0
    else {
      return false
    }

    return isOverflowing(
      contentWidth: contentWidth,
      availableWidth: availableWidth,
      isAccessibilitySize: isAccessibilitySize
    )
  }

  public static func scrollDistance(
    contentWidth: CGFloat,
    availableWidth: CGFloat
  ) -> CGFloat {
    guard contentWidth.isFinite, availableWidth.isFinite else { return 0 }
    return max(0, contentWidth - availableWidth)
  }

  public static func travelDuration(
    distance: CGFloat,
    pointsPerSecond: CGFloat
  ) -> Double {
    guard distance.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0 else {
      return minimumTravelSeconds
    }

    return max(Double(max(0, distance) / pointsPerSecond), minimumTravelSeconds)
  }

  /// The ordered timing and geometry steps for one marquee cycle: dwell at the start, travel to
  /// reveal the end, dwell there, then travel back. The view repeats the cycle for as long as it is
  /// active, so the last step returns the line to where the first step expects it. There is no
  /// instant reset, and the return is the same linear travel as the reveal.
  public static func cycleSchedule(
    distance: CGFloat,
    pointsPerSecond: CGFloat
  ) -> [MarqueePassStep] {
    let resolvedDistance = distance.isFinite && distance > 0 ? distance : 0
    let travel = travelDuration(distance: distance, pointsPerSecond: pointsPerSecond)
    return [
      MarqueePassStep(
        phase: .atStart,
        offset: 0,
        duration: dwellSeconds,
        animated: false
      ),
      MarqueePassStep(
        phase: .travelling,
        offset: -resolvedDistance,
        duration: travel,
        animated: resolvedDistance > 0
      ),
      MarqueePassStep(
        phase: .atEnd,
        offset: -resolvedDistance,
        duration: dwellSeconds,
        animated: false
      ),
      MarqueePassStep(
        phase: .travelling,
        offset: 0,
        duration: travel,
        animated: resolvedDistance > 0
      ),
    ]
  }

  public static func cycleDuration(
    distance: CGFloat,
    pointsPerSecond: CGFloat
  ) -> Double {
    cycleSchedule(distance: distance, pointsPerSecond: pointsPerSecond)
      .reduce(0) { $0 + $1.duration }
  }

  /// The fade at each edge for a cycle phase. Only the hidden side fades: the start dwell must
  /// leave the prefix clear, the end dwell must leave the suffix clear, and a travelling line in
  /// either direction has overflow on both sides.
  public static func edgeFades(
    phase: MarqueePassPhase,
    distance: CGFloat,
    availableWidth: CGFloat
  ) -> (leading: CGFloat, trailing: CGFloat) {
    let leadingOverflow = phase == .atStart ? 0 : distance
    let trailingOverflow = phase == .atEnd ? 0 : distance
    return (
      leading: edgeFadeWidth(overflow: leadingOverflow, availableWidth: availableWidth),
      trailing: edgeFadeWidth(overflow: trailingOverflow, availableWidth: availableWidth)
    )
  }

  /// Where the label sits in its column. An overflowing line is always flush leading because a
  /// faded, unellipsized line centred in its column would hide the start that identifies it. Text
  /// that fits keeps the caller's alignment.
  public static func restingAlignment(
    for requested: Alignment,
    isOverflowing: Bool
  ) -> Alignment {
    isOverflowing ? .leading : requested
  }

  /// The single-line form is the normal marquee shape. Accessibility sizes wrap to two so larger
  /// text is not forced through a fixed-height single line.
  public static func resolvedLineLimit(isAccessibilitySize: Bool) -> Int {
    isAccessibilitySize ? 2 : 1
  }
}

/// A label that reveals overflowing content the way the system players do: it dwells at the
/// start, travels to show the end, dwells there, travels back, and repeats for as long as it is
/// active. Text that fits, Reduce Motion, and accessibility Dynamic Type sizes all stay static; the
/// last wraps to the resolved multiline limit.
public struct MarqueeText: View {
  private let text: String
  private let font: Font
  private let pointsPerSecond: CGFloat
  private let isActive: Bool
  private let alignment: Alignment

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.isMarqueeSuspended) private var isSuspended
  @State private var contentWidth: CGFloat = 0
  @State private var phase: MarqueePassPhase = .atStart
  @State private var offset: CGFloat = 0

  public init(
    _ text: String,
    font: Font,
    pointsPerSecond: CGFloat = MarqueeTextGeometry.defaultPointsPerSecond,
    isActive: Bool = true,
    alignment: Alignment = .leading
  ) {
    self.text = text
    self.font = font
    self.pointsPerSecond = pointsPerSecond
    self.isActive = isActive
    self.alignment = alignment
  }

  public var body: some View {
    let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
    sizingText
      .hidden()
      .overlay {
        GeometryReader { container in
          let availableWidth = container.size.width
          let distance = MarqueeTextGeometry.scrollDistance(
            contentWidth: contentWidth,
            availableWidth: availableWidth
          )
          let shouldScroll =
            isActive
            && MarqueeTextGeometry.shouldScroll(
              contentWidth: contentWidth,
              availableWidth: availableWidth,
              reduceMotion: reduceMotion,
              isAccessibilitySize: isAccessibilitySize,
              isSuspended: isSuspended
            )
          let isOverflowing = MarqueeTextGeometry.isOverflowing(
            contentWidth: contentWidth,
            availableWidth: availableWidth,
            isAccessibilitySize: isAccessibilitySize
          )

          let resolvedAlignment = MarqueeTextGeometry.restingAlignment(
            for: alignment, isOverflowing: isOverflowing)
          let fades = MarqueeTextGeometry.edgeFades(
            phase: phase,
            distance: distance,
            availableWidth: availableWidth
          )

          let clippedContent = ZStack(alignment: resolvedAlignment) {
            if shouldScroll {
              scrollingText(distance: distance)
            } else if isOverflowing {
              overflowingRestingText
            } else {
              restingText(alignment: resolvedAlignment)
            }

            contentMeasurement
          }
          .frame(
            width: container.size.width, height: container.size.height,
            alignment: resolvedAlignment
          )
          .clipped()

          // A mask reads the alpha of what it renders, so the opaque fill has to stop where the
          // gradient starts: a gradient layered over a full-width fill would leave every pixel
          // opaque and fade nothing. Not overflowing → no mask at all; masking forces an
          // offscreen pass that text which fits must not pay.
          if isOverflowing {
            clippedContent.mask {
              HStack(spacing: 0) {
                if fades.leading > 0 {
                  LinearGradient(
                    colors: [.clear, .white],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                  .frame(width: fades.leading)
                }
                Color.white
                if fades.trailing > 0 {
                  LinearGradient(
                    colors: [.white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                  )
                  .frame(width: fades.trailing)
                }
              }
            }
          } else {
            clippedContent
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(text))
  }

  private var sizingText: some View {
    Text(text)
      .font(font)
      .lineLimit(resolvedLineLimit)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: alignment)
  }

  private func restingText(alignment: Alignment) -> some View {
    Text(text)
      .font(font)
      .lineLimit(resolvedLineLimit)
      .frame(maxWidth: .infinity, alignment: alignment)
  }

  private var overflowingRestingText: some View {
    Text(text)
      .font(font)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  private func scrollingText(distance: CGFloat) -> some View {
    Text(text)
      .font(font)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .offset(x: offset)
      // A new title or a material layout change restarts the cycle from the leading edge. Whole-
      // point bucketing avoids restarting the animation for sub-pixel measurement jitter while
      // layout settles.
      .task(id: MarqueeAnimationIdentity(text: text, distance: distance)) {
        resetAnimationState()

        let schedule = MarqueeTextGeometry.cycleSchedule(
          distance: distance,
          pointsPerSecond: pointsPerSecond
        )
        // Nothing to travel means nothing to repeat; the schedule is still walked once so the
        // phase and offset land where the geometry says they should.
        let repeats = schedule.contains { $0.animated }

        repeat {
          for step in schedule {
            guard Task.isCancelled == false else {
              resetAnimationState()
              return
            }

            if step.animated {
              phase = step.phase
              withAnimation(.linear(duration: step.duration)) {
                offset = step.offset
              }
            } else {
              var transaction = Transaction()
              transaction.disablesAnimations = true
              withTransaction(transaction) {
                phase = step.phase
                offset = step.offset
              }
            }

            do {
              try await Task.sleep(for: .seconds(step.duration))
            } catch {
              resetAnimationState()
              return
            }
          }
        } while repeats && Task.isCancelled == false
      }
  }

  private func resetAnimationState() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      phase = .atStart
      offset = 0
    }
  }

  private var contentMeasurement: some View {
    // Load-bearing, not a leftover: `contentWidth` decides `isOverflowing`, `shouldScroll`, and the
    // scroll distance, and the visible resting text is `maxWidth: .infinity`, so it reports the
    // column's width rather than its own and cannot detect the fits-to-overflows transition.
    Text(text)
      .font(font)
      .lineLimit(resolvedLineLimit)
      .fixedSize(horizontal: true, vertical: false)
      .hidden()
      .accessibilityHidden(true)
      .background {
        GeometryReader { measurement in
          Color.clear
            .onAppear {
              contentWidth = measurement.size.width
            }
            .onChange(of: measurement.size.width) { _, width in
              contentWidth = width
            }
        }
      }
  }

  private var resolvedLineLimit: Int {
    MarqueeTextGeometry.resolvedLineLimit(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }
}

private struct MarqueeAnimationIdentity: Hashable {
  let text: String
  let roundedDistance: CGFloat

  init(text: String, distance: CGFloat) {
    self.text = text
    roundedDistance = distance.rounded()
  }
}

extension EnvironmentValues {
  /// Holds every `MarqueeText` below at rest, at the start of its line, for as long as it is set.
  /// Clearing it starts each cycle again from the leading edge. For a host that hides or replaces
  /// the label for a moment and needs it back where a still copy left off.
  @Entry public var isMarqueeSuspended = false
}
