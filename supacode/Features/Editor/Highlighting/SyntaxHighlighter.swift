import AppKit
import Foundation
import SwiftTreeSitter

/// A single resolved highlight: a text range and the capture name that the
/// grammar's `highlights` query assigned to it (e.g. `keyword`, `string`,
/// `type`). `range` is in UTF-16 code units, usable directly as an `NSRange`.
struct SyntaxHighlight: Equatable, Sendable {
  let range: NSRange
  let captureName: String
}

/// Maps tree-sitter `highlights` capture names to colors, using only semantic
/// system colors so the editor tracks light / dark and accessibility settings.
///
/// Capture names are dotted (`keyword.function`, `string.escape`, …). We match
/// most-specific-first by walking the dotted prefix, so `keyword.function`
/// falls back to `keyword` if it isn't individually mapped. Unknown captures
/// get no color (rendered as plain label text by the caller).
enum SyntaxTheme {
  /// The base text color for ranges with no (or unknown) capture.
  static var defaultColor: NSColor { .labelColor }

  /// Resolve a color for a dotted capture name, walking from most to least
  /// specific. Returns `nil` if nothing in the chain is mapped (e.g. a bare
  /// `variable`, which intentionally has no entry so it stays default text
  /// while `variable.member` / `variable.parameter` still get a tint).
  static func color(for captureName: String) -> NSColor? {
    var components = captureName.split(separator: ".").map(String.init)
    while !components.isEmpty {
      if let color = colorTable[components.joined(separator: ".")] {
        return color
      }
      components.removeLast()
    }
    return nil
  }

  /// The non-recursive color table. Keys are capture names (or dotted
  /// prefixes). System colors only — no literals. A bare `variable` is
  /// deliberately absent so it falls through to the default label color.
  private static let colorTable: [String: NSColor] = [
    "keyword": .systemPink,
    "constructor": .systemPurple,
    "type": .systemTeal,
    "string": .systemRed,
    "character": .systemRed,
    "comment": .secondaryLabelColor,
    "number": .systemOrange,
    "boolean": .systemOrange,
    "constant": .systemOrange,
    "function": .systemBlue,
    "variable.member": .systemIndigo,
    "variable.parameter": .systemIndigo,
    "variable.builtin": .systemPurple,
    "attribute": .systemGreen,
    "operator": .secondaryLabelColor,
    "punctuation": .secondaryLabelColor,
    "label": .systemBrown,
  ]
}

/// Pure tree-sitter highlight extraction. Given source text and a language,
/// parse and run the `highlights` query, returning ordered
/// `(range, captureName)` pairs. No UI, no state — testable as statics.
enum SyntaxHighlighter {
  /// Buffers larger than this (in UTF-16 code units) skip highlighting — a full
  /// reparse of a huge file would jank the UI. ~1M chars.
  static let maxHighlightableLength = 1_000_000

  /// Extract highlights for `text` in `language`. Returns `[]` for an unknown
  /// language, an oversized buffer, an unparseable buffer, or a grammar with no
  /// `highlights` query.
  static func highlights(in text: String, language: EditorLanguage?) -> [SyntaxHighlight] {
    guard text.utf16.count <= maxHighlightableLength else { return [] }
    guard let language, let loaded = language.load(), let query = loaded.highlights else {
      return []
    }
    return highlights(in: text, language: loaded.language, query: query)
  }

  /// Lower-level extraction against an already-loaded grammar + highlights
  /// query. Exposed for tests.
  static func highlights(in text: String, language: Language, query: Query) -> [SyntaxHighlight] {
    let parser = Parser()
    do {
      try parser.setLanguage(language)
    } catch {
      return []
    }
    guard let tree = parser.parse(text) else { return [] }

    let cursor = query.execute(in: tree)
    let utf16Count = text.utf16.count

    // `highlights()` sorts least-specific → most-specific so later (more
    // specific) captures override earlier ones when applied in order.
    return
      cursor
      .resolve(with: .init(string: text))
      .highlights()
      .compactMap { namedRange in
        let range = namedRange.range
        guard range.location >= 0, NSMaxRange(range) <= utf16Count, range.length > 0 else {
          return nil
        }
        return SyntaxHighlight(range: range, captureName: namedRange.name)
      }
  }
}
