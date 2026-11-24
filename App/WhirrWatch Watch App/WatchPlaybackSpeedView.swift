import SwiftUI

struct WatchPlaybackSpeedView: View {
  @Environment(\.dismiss) private var dismiss
  var title = "Speed"
  var dismissAfterSelection = false
  var currentRate: Double?
  var presets: [Double]? = nil
  let selectRate: (Double) -> Void

  var body: some View {
    ScrollViewReader { scroll in
      List {
        ForEach(WatchDisplayFormatting.playbackRates(current: currentRate, presets: presets), id: \.self) { rate in
          Button {
            selectRate(rate)
            if dismissAfterSelection { dismiss() }
          } label: {
            HStack {
              Text("\(rate.formatted())×").monospacedDigit()
              Spacer()
              if currentRate == rate { Image(systemName: "checkmark").foregroundStyle(WatchVisualStyle.accent) }
            }.frame(minHeight: 44)
          }
          .accessibilityAddTraits(currentRate == rate ? .isSelected : [])
          .id(rate)
        }
      }
      .onAppear { scroll.scrollTo(currentRate ?? 1, anchor: .center) }
    }.navigationTitle(title)
  }
}
