import AppKit
import Foundation
import Testing

@testable import supacode

/// Coverage for Phase 5b: tree-sitter syntax highlighting + symbol navigation.
/// The pure parse/query/map statics are deterministic against the bundled
/// tree-sitter-swift grammar, so these assert real captures and symbols.
struct EditorHighlightingTests {

  // A fixed multi-declaration snippet exercised by several tests.
  private static let sampleSwift = """
    import Foundation

    struct Point {
      var x: Int
      var y: Int

      func distance() -> Double {
        return 0
      }
    }

    protocol Drawable {
      func draw()
    }

    func makeOrigin() -> Point {
      return Point(x: 0, y: 0)
    }
    """

  // MARK: - Language detection (pure).

  @Test func detectsSwiftFromExtension() {
    #expect(EditorLanguage.forFileExtension("swift") == .swift)
    #expect(EditorLanguage.forFileExtension("SWIFT") == .swift)
    #expect(EditorLanguage.forFileURL(URL(filePath: "/tmp/Foo.swift")) == .swift)
  }

  @Test func unknownExtensionIsPlain() {
    #expect(EditorLanguage.forFileExtension("rs") == nil)
    #expect(EditorLanguage.forFileExtension("") == nil)
    #expect(EditorLanguage.forFileURL(URL(filePath: "/tmp/README.md")) == nil)
    #expect(EditorLanguage.forFileURL(nil) == nil)
  }

  // MARK: - Theme capture → color mapping (pure).

  @Test func themeMapsKnownCapturesToSystemColors() {
    #expect(SyntaxTheme.color(for: "keyword") == .systemPink)
    #expect(SyntaxTheme.color(for: "type") == .systemTeal)
    #expect(SyntaxTheme.color(for: "string") == .systemRed)
    #expect(SyntaxTheme.color(for: "comment") == .secondaryLabelColor)
    #expect(SyntaxTheme.color(for: "number") == .systemOrange)
    #expect(SyntaxTheme.color(for: "function") == .systemBlue)
  }

  @Test func themeFallsBackThroughDottedPrefix() {
    // keyword.function isn't mapped individually → falls back to keyword.
    #expect(SyntaxTheme.color(for: "keyword.function") == .systemPink)
    // function.method / function.call → function.
    #expect(SyntaxTheme.color(for: "function.method") == .systemBlue)
    // variable.member is mapped specifically (variable itself is nil).
    #expect(SyntaxTheme.color(for: "variable.member") == .systemIndigo)
    #expect(SyntaxTheme.color(for: "variable") == nil)
  }

  @Test func themeReturnsNilForUnknownCapture() {
    #expect(SyntaxTheme.color(for: "totally.unknown.capture") == nil)
    #expect(SyntaxTheme.color(for: "") == nil)
  }

  // MARK: - Highlight smoke test (real tree-sitter parse).

  @Test func parsingSwiftYieldsHighlightCaptures() {
    let highlights = SyntaxHighlighter.highlights(in: Self.sampleSwift, language: .swift)
    #expect(!highlights.isEmpty)

    let captureNames = Set(highlights.map(\.captureName))
    // We expect at least keyword + type captures from the snippet.
    #expect(captureNames.contains { $0.hasPrefix("keyword") })
    #expect(captureNames.contains { $0.hasPrefix("type") || $0 == "type" })

    // Every highlight range is in bounds and non-empty.
    let count = Self.sampleSwift.utf16.count
    for highlight in highlights {
      #expect(highlight.range.location >= 0)
      #expect(NSMaxRange(highlight.range) <= count)
      #expect(highlight.range.length > 0)
    }
  }

  @Test func highlightsEmptyForUnknownLanguageAndOversize() {
    #expect(SyntaxHighlighter.highlights(in: Self.sampleSwift, language: nil).isEmpty)
    #expect(SyntaxHighlighter.highlights(in: "", language: .swift).isEmpty)
  }

  // MARK: - Symbol extraction (real tree-sitter parse + tags query).

  @Test func extractsSymbolsInOrder() {
    let symbols = EditorSymbol.symbols(in: Self.sampleSwift, language: .swift)
    #expect(!symbols.isEmpty)

    let names = symbols.map(\.name)
    // Expected declarations from the snippet.
    #expect(names.contains("Point"))
    #expect(names.contains("Drawable"))
    #expect(names.contains("distance"))
    #expect(names.contains("draw"))
    #expect(names.contains("makeOrigin"))
    #expect(names.contains("x"))
    #expect(names.contains("y"))

    // Ordered by source position (non-decreasing location).
    let locations = symbols.map(\.range.location)
    #expect(locations == locations.sorted())

    // Point is declared before makeOrigin in the source.
    if let pointIndex = names.firstIndex(of: "Point"),
      let makeIndex = names.firstIndex(of: "makeOrigin")
    {
      #expect(pointIndex < makeIndex)
    } else {
      Issue.record("Expected both Point and makeOrigin symbols")
    }
  }

  @Test func symbolKindsAreClassified() {
    let symbols = EditorSymbol.symbols(in: Self.sampleSwift, language: .swift)
    let byName = Dictionary(symbols.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })

    #expect(byName["Point"] == .type)
    #expect(byName["Drawable"] == .interface)
    #expect(byName["distance"] == .method)
    #expect(byName["makeOrigin"] == .function)
    #expect(byName["x"] == .property)
  }

  @Test func symbolLineNumbersAreCorrect() {
    let symbols = EditorSymbol.symbols(in: Self.sampleSwift, language: .swift)
    // `struct Point` is on line 3 of the snippet (1: import, 2: blank, 3: struct).
    let point = symbols.first { $0.name == "Point" && $0.kind == .type }
    #expect(point?.line == 3)
  }

  @Test func symbolsEmptyForUnknownLanguage() {
    #expect(EditorSymbol.symbols(in: Self.sampleSwift, language: nil).isEmpty)
    #expect(EditorSymbol.symbols(in: "", language: .swift).isEmpty)
  }
}
