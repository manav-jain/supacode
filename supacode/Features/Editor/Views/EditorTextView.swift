import AppKit
import STTextView
import SwiftUI

/// SwiftUI bridge to the AppKit `STTextView` used as the in-app editor surface.
///
/// STTextView's stock SwiftUI `TextView` is a *controlled* component: it re-pushes
/// the whole `AttributedString` into the text view on every render, which routes
/// through `setString()` and `disableUndoRegistration()` — wiping the native undo
/// stack on each keystroke and forcing syntax colors to be rebuilt-and-replaced
/// constantly. This wrapper instead lets `STTextView` own its buffer and its
/// `NSUndoManager`:
///
/// - We write `textView.text` only when it actually differs from the incoming
///   `text` (i.e. an external load / reload), never as an echo of the user's own
///   typing — so ⌘Z / ⇧⌘Z work natively.
/// - Edits flow *out* via `onTextChange`.
/// - Syntax highlighting is applied elsewhere (`EditorHighlightModel`) as STTextView
///   *rendering* attributes, which only affect drawing and never mutate the
///   document, so coloring is fully decoupled from text and undo.
struct EditorTextView: NSViewRepresentable {
  /// The canonical buffer from the reducer. Used to seed the view and to detect
  /// external changes (load / reload); never echoed back on the user's own edits.
  let text: String
  @Binding var selection: NSRange?
  let isEditable: Bool
  let font: NSFont
  let wrapLines: Bool
  let highlightSelectedLine: Bool
  let plugins: [any STPlugin]
  let onTextChange: (String) -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = STTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? STTextView else {
      return scrollView
    }
    textView.textDelegate = context.coordinator
    textView.highlightSelectedLine = highlightSelectedLine
    textView.isHorizontallyResizable = !wrapLines
    textView.font = font

    textView.textSelection = selection ?? NSRange(location: 0, length: 0)

    context.coordinator.isApplyingExternalText = true
    textView.text = text
    context.coordinator.isApplyingExternalText = false

    for plugin in plugins {
      textView.addPlugin(plugin)
    }

    textView.isEditable = isEditable
    textView.isSelectable = isEditable
    return scrollView
  }

  /// Adopt the size SwiftUI proposes (matching STTextView's stock wrapper). Without
  /// this the scroll view can be handed a degenerate size, which propagates into an
  /// AppKit window constraint-update exception during the display cycle.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    CGSize(
      width: proposal.width ?? nsView.frame.size.width,
      height: proposal.height ?? nsView.frame.size.height
    )
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? STTextView else { return }

    // Only overwrite the buffer on an EXTERNAL change (load / reload). When the
    // store update is just the echo of the user's own edit, `textView.text`
    // already equals `text`, so we skip the write and preserve the undo stack.
    if (textView.text ?? "") != text {
      context.coordinator.isApplyingExternalText = true
      textView.text = text
      context.coordinator.isApplyingExternalText = false
    }

    if let selection, textView.textSelection != selection {
      textView.textSelection = selection
    }

    if textView.isEditable != isEditable {
      textView.isEditable = isEditable
      textView.isSelectable = isEditable
    }

    if textView.font != font {
      textView.font = font
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection, onTextChange: onTextChange)
  }

  @MainActor
  final class Coordinator: STTextViewDelegate {
    @Binding private var selection: NSRange?
    private let onTextChange: (String) -> Void
    /// Set while we push an external buffer so the resulting change notification
    /// isn't mistaken for (and re-emitted as) a user edit.
    var isApplyingExternalText = false

    init(selection: Binding<NSRange?>, onTextChange: @escaping (String) -> Void) {
      _selection = selection
      self.onTextChange = onTextChange
    }

    func textViewDidChangeText(_ notification: Notification) {
      guard !isApplyingExternalText, let textView = notification.object as? STTextView else {
        return
      }
      onTextChange(textView.text ?? "")
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? STTextView else { return }
      let range = textView.textSelection
      if selection != range {
        selection = range
      }
    }
  }
}
