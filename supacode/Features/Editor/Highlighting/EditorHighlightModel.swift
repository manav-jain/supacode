import AppKit
import Foundation
import STTextView
import SupacodeSettingsShared
import SwiftUI

nonisolated private let editorHighlightLogger = SupaLogger("EditorHighlight")

/// View-owned, non-TCA coordinator that turns the editor's plain text + file
/// language into (a) a colored `AttributedString` the STTextView renders and
/// (b) an ordered symbol list for Go-to-Symbol. It debounces reparses on an
/// injected clock so fast typing doesn't re-run tree-sitter on every keystroke.
///
/// Highlighting is applied by mutating the bound `AttributedString` itself —
/// the SwiftUI `TextView` renders whatever attributes the string carries — so
/// no AppKit text-view reference is required for coloring. The text-view
/// reference (captured via `ScrollPlugin`) is needed only to *scroll* to a
/// symbol, which the SwiftUI wrapper's selection binding doesn't do on its own.
@MainActor
@Observable
final class EditorHighlightModel {
  /// The most recently computed symbols for the current buffer, ordered by
  /// position. Drives the Go-to-Symbol picker.
  private(set) var symbols: [EditorSymbol] = []

  /// The base monospaced font applied to the whole buffer. Colors layer on top.
  var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

  /// Detected language for the current file, or `nil` (plain text).
  private(set) var language: EditorLanguage?

  /// The plugin handed to the STTextView; captures the live view for scrolling.
  let scrollPlugin = ScrollPlugin()

  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private var styleTask: Task<Void, Never>?
  /// The last (text, languageKey) we styled, to skip redundant recompute.
  @ObservationIgnored private var lastStyledText: String?
  @ObservationIgnored private var lastStyledLanguage: EditorLanguage?

  init(clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(150)) {
    self.clock = clock
    self.debounce = debounce
  }

  /// Update the detected language from the bound file URL.
  func setFileURL(_ url: URL?) {
    language = EditorLanguage.forFileURL(url)
  }

  /// Build the colored `AttributedString` for `text` synchronously using the
  /// latest computed symbols' sibling highlights. This is what the view binds
  /// for reads — it always reflects the current `text`, with whatever
  /// highlights were last computed for that exact text (else just the base
  /// font, so a not-yet-restyled buffer still renders correctly).
  func styledString(for text: String) -> AttributedString {
    var attributed = AttributedString(text)
    attributed.font = font
    attributed.foregroundColor = SyntaxTheme.defaultColor

    // Only color if the cached highlights were computed for this exact text.
    guard text == lastStyledText, !cachedHighlights.isEmpty else {
      return attributed
    }
    apply(cachedHighlights, to: &attributed, textUTF16Count: text.utf16.count)
    return attributed
  }

  /// Kick off a debounced restyle for the given text. When it completes, the
  /// cached highlights + symbols are updated and `objectWillChange` fires via
  /// `@Observable`, prompting the view to re-read `styledString(for:)`.
  func scheduleHighlight(for text: String) {
    // Skip if nothing relevant changed.
    if text == lastStyledText, language == lastStyledLanguage {
      return
    }

    styleTask?.cancel()
    let language = language
    let clock = clock
    let debounce = debounce
    styleTask = Task { [weak self] in
      try? await clock.sleep(for: debounce)
      if Task.isCancelled { return }

      let highlights = SyntaxHighlighter.highlights(in: text, language: language)
      let symbols = EditorSymbol.symbols(in: text, language: language)
      if Task.isCancelled { return }

      guard let self else { return }
      self.cachedHighlights = highlights
      self.symbols = symbols
      self.lastStyledText = text
      self.lastStyledLanguage = language
      // Bump an observed token so SwiftUI re-reads styledString(for:).
      self.styleGeneration &+= 1
    }
  }

  /// Scroll the underlying text view to a symbol and select its declaration.
  /// The selection binding handles selection; this guarantees the scroll.
  func reveal(_ symbol: EditorSymbol) {
    scrollPlugin.textView?.scrollRangeToVisible(symbol.range)
  }

  /// Scroll the underlying text view to the start of the given 1-based `line`
  /// in `text` and return the line's start range so the caller can also drive
  /// the selection binding. Returns `nil` when the line is out of bounds.
  /// Reuses the same `scrollRangeToVisible` mechanism as Go-to-Symbol (Phase 5b).
  @discardableResult
  func revealLine(_ line: Int, in text: String) -> NSRange? {
    guard let range = Self.startRange(ofLine: line, in: text) else { return nil }
    scrollPlugin.textView?.scrollRangeToVisible(range)
    return range
  }

  /// Compute the zero-length `NSRange` (UTF-16) at the start of the 1-based
  /// `line` in `text`. Newlines are counted as `\n`; a `\r\n` file still lands
  /// on the right offset because the `\r` is part of the preceding line. Returns
  /// `nil` when `line` is below 1 or past the last line.
  static func startRange(ofLine line: Int, in text: String) -> NSRange? {
    guard line >= 1 else { return nil }
    if line == 1 { return NSRange(location: 0, length: 0) }
    var utf16Offset = 0
    var currentLine = 1
    for unit in text.utf16 {
      utf16Offset += 1
      if unit == 0x0A {  // newline
        currentLine += 1
        if currentLine == line {
          return NSRange(location: utf16Offset, length: 0)
        }
      }
    }
    return nil
  }

  // MARK: - Internals

  /// Bumped whenever a restyle finishes; observed so the view re-renders.
  private(set) var styleGeneration: Int = 0

  @ObservationIgnored private var cachedHighlights: [SyntaxHighlight] = []

  /// Layer color attributes onto the attributed string. Highlights arrive
  /// least-specific first, so applying in order lets specific captures win.
  private func apply(_ highlights: [SyntaxHighlight], to attributed: inout AttributedString, textUTF16Count: Int) {
    for highlight in highlights {
      guard let color = SyntaxTheme.color(for: highlight.captureName) else { continue }
      guard
        let range = Range(highlight.range, in: attributed),
        NSMaxRange(highlight.range) <= textUTF16Count
      else { continue }
      attributed[range].foregroundColor = color
    }
  }
}

/// A tiny STTextView plugin whose only job is to hand us the live `STTextView`
/// instance so we can call `scrollRangeToVisible` for Go-to-Symbol. It adds no
/// editing behavior.
@MainActor
final class ScrollPlugin: STPlugin {
  weak var textView: STTextView?

  func setUp(context: any Context) {
    textView = context.textView
  }

  func tearDown() {
    textView = nil
  }
}
