import AppModel
import Foundation

/// The chapters chosen in a chapter sheet's Select mode, in the order they were tapped. That order
/// is the order "Add to Up Next" queues them in, so each chosen row shows its number.
struct ChapterSelection: Equatable {
  private(set) var order: [ChapterSelectorRow.ID] = []

  var count: Int { order.count }

  mutating func toggle(_ id: ChapterSelectorRow.ID) {
    if let index = order.firstIndex(of: id) {
      order.remove(at: index)
    } else {
      order.append(id)
    }
  }

  /// The row's place in the queuing order, from 1; `nil` when it is not chosen.
  func number(of id: ChapterSelectorRow.ID) -> Int? {
    order.firstIndex(of: id).map { $0 + 1 }
  }

  /// The chosen rows in the order they were tapped.
  func rows(in rows: [ChapterSelectorRow]) -> [ChapterSelectorRow] {
    order.compactMap { id in rows.first { $0.id == id } }
  }

  // MARK: - Presentation

  static let selectLabel = "Select"
  static let cancelLabel = "Cancel"
  static let selectHint = "Choose chapters to add to Up Next in order."

  /// SF Symbols numbers its circles up to 50; past that a chosen row shows a plain check.
  static func indicatorSymbol(number: Int?) -> String {
    guard let number else { return "circle" }
    return number <= 50 ? "\(number).circle.fill" : "checkmark.circle.fill"
  }

  static func addLabel(count: Int) -> String {
    MediaActionCopy.addToUpNext(count: count)
  }

  static func accessibilityValue(number: Int?) -> String {
    number.map { "Selected, \($0) in order" } ?? "Not selected"
  }
}
