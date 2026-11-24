import AppModel
import SwiftUI

/// The Download control a multiselect toolbar offers, shared by every screen with a batch
/// selection. A sole-format selection is one tap; a mixed selection must name the medium, because
/// the batch cannot infer which of audio, eBook, or both the listener meant.
struct SelectionDownloadControl: View {
  let hasFormatChoice: Bool
  let isDisabled: Bool
  /// Omitted on a surface that publishes no identifier for this control.
  let accessibilityID: String?
  /// Library Titles drew the download glyph on each format row; the other toolbars drew text.
  let showsFormatSymbols: Bool
  let request: (ItemDownloadFormat?) -> Void

  init(
    hasFormatChoice: Bool,
    isDisabled: Bool,
    accessibilityID: String? = nil,
    showsFormatSymbols: Bool = false,
    request: @escaping (ItemDownloadFormat?) -> Void
  ) {
    self.hasFormatChoice = hasFormatChoice
    self.isDisabled = isDisabled
    self.accessibilityID = accessibilityID
    self.showsFormatSymbols = showsFormatSymbols
    self.request = request
  }

  var body: some View {
    if hasFormatChoice {
      Menu {
        formatButton("Download Audio", format: .audio)
        formatButton("Download eBooks", format: .ebook)
        formatButton("Download All Available Formats", format: .both)
      } label: {
        Label(MediaActionCopy.download.title, systemImage: MediaActionCopy.download.systemImage)
      }
      .disabled(isDisabled)
      .selectionDownloadAccessibilityID(accessibilityID)
    } else {
      Button(MediaActionCopy.download.title, systemImage: MediaActionCopy.download.systemImage) { request(nil) }
        .disabled(isDisabled)
        .selectionDownloadAccessibilityID(accessibilityID)
    }
  }

  private func formatButton(_ title: String, format: ItemDownloadFormat) -> some View {
    Button {
      request(format)
    } label: {
      if showsFormatSymbols {
        Label(title, systemImage: "arrow.down.circle")
      } else {
        Text(title)
      }
    }
  }
}

extension View {
  @ViewBuilder
  fileprivate func selectionDownloadAccessibilityID(_ identifier: String?) -> some View {
    if let identifier {
      accessibilityIdentifier(identifier)
    } else {
      self
    }
  }
}
