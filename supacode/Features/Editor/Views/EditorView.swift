import ComposableArchitecture
import STTextViewSwiftUI
import STTextViewSwiftUICommon
import SwiftUI

/// The in-app editor surface. Wraps STTextView's SwiftUI `TextView` (2.3.10),
/// which binds an `AttributedString`; we bridge that to the feature's plain
/// `String` buffer. v1 is plain monospaced editing with system colors — NO
/// syntax highlighting (Phase 5). Shows an inline empty state when no file is
/// bound and an error state when a load fails.
struct EditorView: View {
  @Bindable var store: StoreOf<EditorFeature>

  var body: some View {
    Group {
      if let loadError = store.loadError {
        errorState(message: loadError)
      } else if store.fileURL == nil {
        emptyState
      } else {
        editor
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    // ⌘S — explicit save. Hidden command button so the shortcut is owned by the
    // focused editor without adding chrome.
    .background {
      Button("Save") { store.send(.save) }
        .keyboardShortcut("s", modifiers: .command)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var editor: some View {
    TextView(
      text: textBinding,
      selection: .constant(nil),
      options: [.wrapLines, .highlightSelectedLine]
    )
    .textViewFont(.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
    .disabled(store.isLoading)
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No File Open",
      systemImage: "doc.text",
      description: Text("Open a file to start editing.")
    )
  }

  private func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn't Open File", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    }
  }

  /// Bridges the feature's plain `String` buffer to STTextView's
  /// `AttributedString` binding. Reads convert `String` → `AttributedString`;
  /// writes extract the characters and send `.textChanged` (no direct state
  /// mutation, per the `store_state_mutation_in_views` lint rule).
  private var textBinding: Binding<AttributedString> {
    Binding(
      get: { AttributedString(store.text) },
      set: { newValue in
        let plain = String(newValue.characters)
        guard plain != store.text else { return }
        store.send(.textChanged(plain))
      }
    )
  }
}
