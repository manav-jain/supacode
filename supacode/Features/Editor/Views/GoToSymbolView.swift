import SwiftUI

/// A filterable Go-to-Symbol overlay (⇧⌘O): a search field over the file's
/// declarations, each row showing the symbol's kind icon, name, and line. The
/// list filters live as the user types; Return selects the top match, Escape
/// dismisses. Selection scrolls the editor to and selects the declaration.
struct GoToSymbolView: View {
  let symbols: [EditorSymbol]
  let onSelect: (EditorSymbol) -> Void
  let onDismiss: () -> Void

  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private var filtered: [EditorSymbol] {
    guard !query.isEmpty else { return symbols }
    return symbols.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      symbolList
    }
    .frame(width: 360)
    .frame(maxHeight: 320)
    .background(.regularMaterial, in: .rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
    .shadow(radius: 16, y: 4)
    .onAppear { searchFocused = true }
    .onExitCommand(perform: onDismiss)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Go to Symbol", text: $query)
        .textFieldStyle(.plain)
        .focused($searchFocused)
        .onSubmit {
          if let first = filtered.first { onSelect(first) }
        }
    }
    .padding(10)
  }

  @ViewBuilder private var symbolList: some View {
    if filtered.isEmpty {
      ContentUnavailableView(
        symbols.isEmpty ? "No Symbols" : "No Matches",
        systemImage: "magnifyingglass",
        description: Text(
          symbols.isEmpty
            ? "This file has no navigable declarations."
            : "No symbol matches \"\(query)\".")
      )
      .padding()
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(filtered) { symbol in
            Button {
              onSelect(symbol)
            } label: {
              SymbolRow(symbol: symbol)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(4)
      }
    }
  }
}

/// One row in the Go-to-Symbol list: kind icon + name + line number.
private struct SymbolRow: View {
  let symbol: EditorSymbol

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol.kind.systemImage)
        .foregroundStyle(.tint)
        .frame(width: 18)
        .help(symbol.kind.displayName)
        .accessibilityLabel(symbol.kind.displayName)
      Text(symbol.name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text("\(symbol.line)")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .contentShape(.rect)
  }
}
