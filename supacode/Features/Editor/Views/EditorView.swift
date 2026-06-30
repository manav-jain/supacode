import ComposableArchitecture
import STTextViewSwiftUI
import STTextViewSwiftUICommon
import SwiftUI

/// The in-app editor surface. Wraps STTextView's SwiftUI `TextView` (2.3.10),
/// which binds an `AttributedString`; we bridge that to the feature's plain
/// `String` buffer and layer tree-sitter syntax highlighting on top (Phase 5b).
///
/// Highlighting + symbol extraction run in `EditorHighlightModel`, a non-TCA
/// `@Observable` coordinator owned by the view: it parses the buffer with
/// tree-sitter (Swift today; the language registry is extensible), colors the
/// bound `AttributedString`, and exposes the file's declarations for the
/// Go-to-Symbol picker (⇧⌘O). Shows an inline empty state when no file is bound
/// and an error state when a load fails.
struct EditorView: View {
  @Bindable var store: StoreOf<EditorFeature>
  @State private var highlightModel = EditorHighlightModel()
  @State private var selection: NSRange?
  @State private var isShowingSymbols = false

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
    // ⇧⌘O — Go to Symbol.
    .background {
      Button("Go to Symbol") { isShowingSymbols = true }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(highlightModel.symbols.isEmpty)
    }
    .onAppear {
      highlightModel.setFileURL(store.fileURL)
      highlightModel.scheduleHighlight(for: store.text)
    }
    .onChange(of: store.fileURL) { _, newValue in
      highlightModel.setFileURL(newValue)
      highlightModel.scheduleHighlight(for: store.text)
    }
    .onChange(of: store.text) { _, newValue in
      highlightModel.scheduleHighlight(for: newValue)
    }
  }

  private var editor: some View {
    // Reading `styleGeneration` here ties the body to highlight completions so
    // the colored attributed string is re-read once tree-sitter finishes.
    _ = highlightModel.styleGeneration
    return
      TextView(
        text: textBinding,
        selection: $selection,
        options: [.wrapLines, .highlightSelectedLine],
        plugins: [highlightModel.scrollPlugin]
      )
      .textViewFont(highlightModel.font)
      .disabled(store.isLoading)
      .overlay(alignment: .top) {
        symbolPicker
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if store.externallyModified {
          externalChangeBanner
        }
      }
  }

  /// Non-blocking banner shown when the open file changed on disk while the
  /// buffer had unsaved edits. Lets the user discard local changes (Reload) or
  /// keep them (the next save overwrites disk).
  private var externalChangeBanner: some View {
    HStack(spacing: 12) {
      Label("This file changed on disk", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Reload") { store.send(.reloadFromDisk) }
        .help("Discard your local changes and reload the file from disk")
      Button("Keep My Changes") { store.send(.keepLocalChanges) }
        .help("Keep your edits; the next save overwrites the version on disk")
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }

  @ViewBuilder private var symbolPicker: some View {
    if isShowingSymbols {
      GoToSymbolView(symbols: highlightModel.symbols) { symbol in
        isShowingSymbols = false
        selection = symbol.range
        highlightModel.reveal(symbol)
      } onDismiss: {
        isShowingSymbols = false
      }
      .padding(.top, 8)
    }
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
  /// `AttributedString` binding. Reads produce the syntax-colored string from
  /// `EditorHighlightModel`; writes extract the characters and send
  /// `.textChanged` (no direct state mutation, per the
  /// `store_state_mutation_in_views` lint rule).
  private var textBinding: Binding<AttributedString> {
    Binding(
      get: { highlightModel.styledString(for: store.text) },
      set: { newValue in
        let plain = String(newValue.characters)
        guard plain != store.text else { return }
        store.send(.textChanged(plain))
      }
    )
  }
}
