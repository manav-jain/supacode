import Foundation
import SwiftTreeSitter

/// A navigable declaration extracted from a source file via the grammar's
/// `tags` query — a function, method, type, or property the user can jump to
/// with "Go to Symbol".
struct EditorSymbol: Equatable, Identifiable, Sendable {
  /// The kind of declaration, derived from the `tags` query's
  /// `@definition.*` capture. Drives the SF Symbol shown in the picker and
  /// the grouping order.
  enum Kind: String, Equatable, Sendable, CaseIterable {
    case type
    case interface
    case method
    case function
    case property

    /// The `@definition.<suffix>` capture suffix this kind maps to.
    init?(definitionSuffix: String) {
      switch definitionSuffix {
      case "class", "type", "struct", "enum":
        self = .type
      case "interface", "protocol":
        self = .interface
      case "method":
        self = .method
      case "function":
        self = .function
      case "property", "field", "constant":
        self = .property
      default:
        return nil
      }
    }

    /// An SF Symbol name for the picker row.
    var systemImage: String {
      switch self {
      case .type: return "cube"
      case .interface: return "p.circle"
      case .method: return "function"
      case .function: return "f.cursive"
      case .property: return "diamond"
      }
    }

    /// Human-readable label for the picker.
    var displayName: String {
      switch self {
      case .type: return "Type"
      case .interface: return "Protocol"
      case .method: return "Method"
      case .function: return "Function"
      case .property: return "Property"
      }
    }
  }

  /// Stable identity for the SwiftUI list / `Identifiable`.
  var id: String { "\(kind.rawValue):\(name):\(range.location):\(range.length)" }

  /// The declared identifier (the `@name` capture text).
  let name: String
  let kind: Kind
  /// The `@name` capture range in UTF-16 code units, suitable as an `NSRange`
  /// against the editor's text storage. Selecting / scrolling targets this.
  let range: NSRange
  /// 1-based line number of the declaration, for display.
  let line: Int

  /// Extract symbols from `text` using the language's `tags` query, ordered by
  /// source position. Pure: parse → query → map. Returns `[]` for an unknown
  /// language, an unparseable buffer, or a grammar without a `tags` query.
  static func symbols(in text: String, language: EditorLanguage?) -> [EditorSymbol] {
    guard let language, let loaded = language.load(), let tagsQuery = loaded.tags else {
      return []
    }
    return symbols(in: text, language: loaded.language, tagsQuery: tagsQuery)
  }

  /// Lower-level extraction against an already-loaded grammar + tags query.
  /// Exposed for tests that want to drive a specific query.
  static func symbols(in text: String, language: Language, tagsQuery: Query) -> [EditorSymbol] {
    let parser = Parser()
    do {
      try parser.setLanguage(language)
    } catch {
      return []
    }
    guard let tree = parser.parse(text) else { return [] }

    let utf16 = Array(text.utf16)
    var results: [EditorSymbol] = []

    let cursor = tagsQuery.execute(in: tree)
    while let match = cursor.next() {
      // Each tags match pairs a `@definition.<kind>` capture (the enclosing
      // declaration) with a `@name` capture (the identifier to jump to).
      var definitionSuffix: String?
      var nameCapture: QueryCapture?

      for capture in match.captures {
        guard let captureName = capture.name else { continue }
        if captureName.hasPrefix("definition.") {
          definitionSuffix = String(captureName.dropFirst("definition.".count))
        } else if captureName == "name" {
          nameCapture = capture
        }
      }

      guard
        let suffix = definitionSuffix,
        let kind = Kind(definitionSuffix: suffix),
        let nameCapture
      else { continue }

      let range = nameCapture.range
      guard let identifier = substring(of: utf16, range: range), !identifier.isEmpty else { continue }

      let line = lineNumber(forUTF16Offset: range.location, in: utf16)
      results.append(EditorSymbol(name: identifier, kind: kind, range: range, line: line))
    }

    // Order by position; de-dupe identical (kind,name,range) tuples that some
    // tags queries emit via overlapping patterns (e.g. the generic
    // property_declaration plus the class_body-scoped one).
    var seen = Set<String>()
    return
      results
      .sorted { lhs, rhs in
        lhs.range.location != rhs.range.location
          ? lhs.range.location < rhs.range.location : lhs.range.length < rhs.range.length
      }
      .filter { seen.insert($0.id).inserted }
  }

  /// Extract the substring covered by an `NSRange` of UTF-16 code units.
  private static func substring(of utf16: [UInt16], range: NSRange) -> String? {
    guard range.location >= 0, NSMaxRange(range) <= utf16.count else { return nil }
    let slice = utf16[range.location..<NSMaxRange(range)]
    return String(utf16CodeUnits: Array(slice), count: slice.count)
  }

  /// 1-based line number for a UTF-16 offset (counts newlines before it).
  private static func lineNumber(forUTF16Offset offset: Int, in utf16: [UInt16]) -> Int {
    let newline: UInt16 = 0x0A
    var line = 1
    var index = 0
    let bound = min(offset, utf16.count)
    while index < bound {
      if utf16[index] == newline { line += 1 }
      index += 1
    }
    return line
  }
}
