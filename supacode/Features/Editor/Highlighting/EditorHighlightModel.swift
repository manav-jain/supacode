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

  /// The plugin that installs + drives the git change-indicator strip (Phase 10).
  let gutterStripPlugin = EditorGutterStripPlugin()

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

  /// Kick off a debounced restyle for the given text. When it completes, the
  /// cached highlights + symbols are updated and the highlights are painted onto
  /// the live text view as rendering attributes (see `applyCachedHighlights`).
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
      self.applyCachedHighlights()
    }
  }

  /// Scroll the underlying text view to a symbol and select its declaration.
  /// The selection binding handles selection; this guarantees the scroll.
  func reveal(_ symbol: EditorSymbol) {
    scrollPlugin.textView?.scrollRangeToVisible(symbol.range)
  }

  /// Push the latest git per-line change kinds to the gutter strip.
  func updateGutter(status: [Int: EditorGutterChangeKind]) {
    gutterStripPlugin.update(status: status)
  }

  /// The 1-based line number containing the start of `range` in `text`, or `nil`
  /// when there's no selection. Used to drive the inline-blame bar from the
  /// editor's current caret line. Counts `\n` up to the range's UTF-16 location.
  static func lineNumber(forUTF16Offset offset: Int, in text: String) -> Int {
    guard offset > 0 else { return 1 }
    var line = 1
    var seen = 0
    for unit in text.utf16 {
      if seen >= offset { break }
      if unit == 0x0A { line += 1 }
      seen += 1
    }
    return line
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

  @ObservationIgnored private var cachedHighlights: [SyntaxHighlight] = []

  /// Paint the cached tree-sitter highlights onto the live text view as STTextView
  /// *rendering* attributes (draw-only — they never mutate the document, so the
  /// undo stack is untouched). Safe to call repeatedly: `EditorView.onAppear`
  /// calls it so a tab switched back into (with a possibly fresh text view)
  /// re-colors without a reparse. No-ops until `ScrollPlugin` has captured the
  /// text view, or while the buffer is empty.
  func applyCachedHighlights() {
    guard let textView = scrollPlugin.textView else { return }
    let count = (textView.text ?? "").utf16.count
    guard count > 0 else { return }
    let fullRange = NSRange(location: 0, length: count)
    // Reset to the view's default text color, then overlay each capture's color.
    textView.removeRenderingAttribute(.foregroundColor, range: fullRange)
    for highlight in cachedHighlights {
      guard let color = SyntaxTheme.color(for: highlight.captureName) else { continue }
      guard NSMaxRange(highlight.range) <= count else { continue }
      textView.addRenderingAttributes([.foregroundColor: color], range: highlight.range)
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
