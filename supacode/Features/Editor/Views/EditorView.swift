import ComposableArchitecture
import STTextView
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
    content
      .onAppear {
        highlightModel.setFileURL(store.fileURL)
        highlightModel.scheduleHighlight(for: store.text)
        // Re-paint already-computed colors in case this tab's text view was
        // rebuilt while switched away (the reparse above is skipped when nothing
        // changed, so it wouldn't re-color on its own).
        highlightModel.applyCachedHighlights()
        highlightModel.updateGutter(status: store.gutterStatus)
        revealPendingLineIfReady()
        // Compute the gutter strip for the file that's already loaded.
        store.send(.refreshGutter)
      }
      .onChange(of: store.fileURL) { _, newValue in
        highlightModel.setFileURL(newValue)
        highlightModel.scheduleHighlight(for: store.text)
        store.send(.refreshGutter)
      }
      .onChange(of: store.text) { _, newValue in
        highlightModel.scheduleHighlight(for: newValue)
        // The buffer just landed (load or external reload) — if a find-in-files
        // open seeded a pending line, jump to it now that the text exists.
        revealPendingLineIfReady()
      }
      .onChange(of: store.pendingScrollLine) { _, _ in
        // A new jump target arrived (e.g. re-activating a match in an already-open
        // file, where the text doesn't change). Reveal it immediately.
        revealPendingLineIfReady()
      }
      .onChange(of: store.isLoading) { _, isLoading in
        if !isLoading {
          revealPendingLineIfReady()
          // The buffer just settled (load / reload finished) — recompute the
          // gutter change strip against HEAD. Lazy, not per-keystroke.
          store.send(.refreshGutter)
        }
      }
      .onChange(of: store.isDirty) { _, isDirty in
        // A save landed (dirty → clean) without a reload: the working tree
        // changed, so refresh the gutter strip. Guard on the transition so a
        // keystroke flipping to dirty doesn't trigger a git probe.
        if !isDirty {
          store.send(.refreshGutter)
        }
      }
      .onChange(of: store.gutterStatus) { _, status in
        highlightModel.updateGutter(status: status)
      }
  }

  /// The editor surface plus its hidden command buttons. Split out from `body`
  /// so the lifecycle `onChange` chain doesn't push the body expression past the
  /// type-checker's complexity budget.
  private var content: some View {
    Group {
      if let loadError = store.loadError {
        errorState(message: loadError)
      } else if store.fileURL == nil {
        emptyState
      } else if store.showingDiff {
        DiffView(diff: store.diff, isLoading: store.isDiffLoading)
      } else {
        editor
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    // The diff + blame toggles sit at the top-trailing corner whenever a file is
    // bound, so they're available both from the editor and the diff panel.
    .overlay(alignment: .topTrailing) {
      if store.fileURL != nil, store.loadError == nil {
        HStack(spacing: 6) {
          blameToggleButton
          diffToggleButton
        }
        .padding(8)
      }
    }
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
  }

  /// Toolbar button that toggles the working-tree-vs-HEAD diff view. Tinted while
  /// the diff is showing so its on/off state reads at a glance.
  private var diffToggleButton: some View {
    Button {
      store.send(.toggleDiff)
    } label: {
      Label("Diff", systemImage: "plusminus")
        .labelStyle(.iconOnly)
    }
    .buttonStyle(.bordered)
    .tint(store.showingDiff ? .accentColor : nil)
    .controlSize(.small)
    .help(store.showingDiff ? "Hide changes (return to editing)" : "Show changes since HEAD")
  }

  /// Toolbar button that toggles inline git blame for the focused line. Tinted
  /// while blame is showing. Hidden in diff mode (blame applies to the editable
  /// buffer, not the diff panel).
  @ViewBuilder private var blameToggleButton: some View {
    if !store.showingDiff {
      Button {
        store.send(.toggleBlame)
      } label: {
        Label("Blame", systemImage: "person.text.rectangle")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.bordered)
      .tint(store.showingBlame ? .accentColor : nil)
      .controlSize(.small)
      .help(store.showingBlame ? "Hide git blame" : "Show git blame for the current line")
    }
  }

  /// Scroll to `store.pendingScrollLine` once the buffer is loaded, then clear
  /// the pending jump. No-ops when there's nothing pending or the file is still
  /// loading. Reuses `EditorHighlightModel.revealLine`, which drives the same
  /// `scrollRangeToVisible` path as Go-to-Symbol (Phase 5b).
  private func revealPendingLineIfReady() {
    guard let line = store.pendingScrollLine, !store.isLoading, store.loadError == nil else { return }
    if let range = highlightModel.revealLine(line, in: store.text) {
      selection = range
    }
    store.send(.scrollLineConsumed)
  }

  private var editor: some View {
    // A custom AppKit wrapper (not STTextView's stock SwiftUI `TextView`): the
    // text view owns its buffer + native undo, edits flow out via `onTextChange`,
    // and syntax colors are painted as rendering attributes by `highlightModel`
    // — so ⌘Z works and highlighting never round-trips through the buffer.
    EditorTextView(
      text: store.text,
      selection: $selection,
      isEditable: !store.isLoading,
      font: highlightModel.font,
      wrapLines: true,
      highlightSelectedLine: true,
      plugins: [highlightModel.scrollPlugin, highlightModel.gutterStripPlugin],
      onTextChange: { newText in
        guard newText != store.text else { return }
        store.send(.textChanged(newText))
      }
    )
    .overlay(alignment: .top) {
      symbolPicker
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if store.externallyModified {
        externalChangeBanner
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if store.showingBlame {
        blameBar
      }
    }
  }

  /// Subtle bottom bar showing `git blame` for the line the caret is on. Dimmed /
  /// secondary so it never competes with the code. Shows a loading state while
  /// blame computes, a "no attribution" hint when the line isn't blameable, and
  /// `commit · author · relative-date · summary` otherwise.
  private var blameBar: some View {
    HStack(spacing: 8) {
      if store.isBlameLoading {
        ProgressView()
          .controlSize(.small)
        Text("Loading blame…")
          .foregroundStyle(.secondary)
      } else if let line = currentBlameLine {
        if line.isUncommitted {
          Label("Not committed yet", systemImage: "pencil")
            .foregroundStyle(.secondary)
        } else {
          Text(line.commit)
            .monospaced()
            .foregroundStyle(.secondary)
          Text(line.author)
            .foregroundStyle(.secondary)
          if let date = line.timestamp {
            Text(date, format: .relative(presentation: .named))
              .foregroundStyle(.tertiary)
          }
          Text(line.summary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      } else {
        Text("No blame for this line")
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.regularMaterial)
    .overlay(alignment: .top) {
      Divider()
    }
  }

  /// The blame attribution for the line the caret is currently on, resolved from
  /// the selection's UTF-16 offset against the buffer. `nil` when there's no
  /// blame loaded or the line isn't attributed.
  private var currentBlameLine: BlameLine? {
    guard let blame = store.blame else { return nil }
    let offset = selection?.location ?? 0
    let line = EditorHighlightModel.lineNumber(forUTF16Offset: offset, in: store.text)
    return blame.line(line)
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
}
