import Foundation

extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func paragraphs() -> [String] {
    components(separatedBy: CharacterSet.newlines)
      .map(\.trimmed)
      .filter { !$0.isEmpty }
  }

  var fourCharCode: FourCharCode {
    utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
  }
}
