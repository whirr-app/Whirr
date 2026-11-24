import SwiftUI

/// The loaded title's chapters. Choosing one moves the Watch's playhead to its start and closes the list.
struct WatchChapterListView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchAudioEngine.self) private var audio
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let rows = WatchDisplayFormatting.chapterRows(audio.chapters, duration: audio.duration, position: audio.position)
    ScrollViewReader { scroll in
      List(rows) { row in
        Button {
          Task { await model.seek(to: row.start) }
          dismiss()
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title).lineLimit(2)
              Text(WatchDisplayFormatting.playerClock(row.start))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if row.isCurrent { Image(systemName: "checkmark").foregroundStyle(WatchVisualStyle.accent) }
          }.frame(minHeight: 44)
        }
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .id(row.id)
      }
      .onAppear {
        if let current = rows.first(where: \.isCurrent) { scroll.scrollTo(current.id, anchor: .center) }
      }
    }.navigationTitle("Chapters")
  }
}
