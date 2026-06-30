import ComposableArchitecture
import Foundation
import SwiftUI

/// Find-in-files content-search overlay (VS Code ⇧⌘F style). Mirrors the visual
/// structure of `FileSearchOverlayView` — a centered `.ultraThinMaterial` card
/// with a query field, scope toggle, options toggles, divider, and a scrollable
/// results list — but renders `ContentMatch` rows showing `relativePath:line`
/// plus the matched line with the matched span emphasized.
struct ContentSearchOverlayView: View {
  @Bindable var store: StoreOf<ContentSearchFeature>
  @FocusState private var isQueryFocused: Bool
  @State private var hoveredID: ContentMatch.ID?

  var body: some View {
    ZStack {
      if store.isPresented {
        ZStack {
          Color.clear
            .contentShape(.rect)
            .onTapGesture {
              store.send(.setPresented(false))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Dismiss Find in Files")

          GeometryReader { geometry in
            let topOffset = max(
              0,
              geometry.size.height * 0.3
                - ContentSearchCard.fieldHeight / 2
                - ContentSearchCard.padding
            )
            VStack {
              ContentSearchCard(
                query: $store.query,
                selectedIndex: $store.selectedIndex,
                results: store.results,
                scope: store.state.scope,
                onScopeChange: { store.send(.setScope($0)) },
                caseSensitive: store.options.caseSensitive,
                onCaseSensitiveChange: { store.send(.setCaseSensitive($0)) },
                regex: store.options.regex,
                onRegexChange: { store.send(.setRegex($0)) },
                hoveredID: $hoveredID,
                isQueryFocused: _isQueryFocused,
                onEvent: { event in
                  switch event {
                  case .exit:
                    store.send(.setPresented(false))
                  case .submit:
                    submitSelected()
                  case .move(.up):
                    store.send(.moveSelection(.up, itemsCount: store.results.count))
                  case .move(.down):
                    store.send(.moveSelection(.down, itemsCount: store.results.count))
                  case .move:
                    break
                  }
                },
                activate: { id in
                  activate(id)
                }
              )
              .zIndex(1)
              .task {
                isQueryFocused = store.isPresented
              }

              Spacer(minLength: 0)
            }
            .frame(
              width: geometry.size.width,
              height: geometry.size.height,
              alignment: .top
            )
            .padding(.top, topOffset)
          }
        }
      }
    }
    .onChange(of: store.isPresented) { _, newValue in
      isQueryFocused = newValue
      if !newValue {
        hoveredID = nil
      }
    }
  }

  private func submitSelected() {
    let rows = store.results
    guard !rows.isEmpty else { return }
    if let selectedIndex = store.selectedIndex, rows.indices.contains(selectedIndex) {
      store.send(.activate(rows[selectedIndex]))
      return
    }
    store.send(.activate(rows[0]))
  }

  private func activate(_ id: ContentMatch.ID) {
    guard let match = store.results.first(where: { $0.id == id }) else { return }
    store.send(.activate(match))
  }
}

private enum ContentSearchKeyboardEvent: Equatable {
  case exit
  case submit
  case move(MoveCommandDirection)
}

private struct ContentSearchCard: View {
  static let padding: CGFloat = 16
  static let fieldHeight: CGFloat = 48

  @Binding var query: String
  @Binding var selectedIndex: Int?
  let results: [ContentMatch]
  let scope: ContentSearchFeature.Scope
  let onScopeChange: (ContentSearchFeature.Scope) -> Void
  let caseSensitive: Bool
  let onCaseSensitiveChange: (Bool) -> Void
  let regex: Bool
  let onRegexChange: (Bool) -> Void
  @Binding var hoveredID: ContentMatch.ID?
  let isQueryFocused: FocusState<Bool>
  let onEvent: (ContentSearchKeyboardEvent) -> Void
  let activate: (ContentMatch.ID) -> Void

  private var backgroundColor: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  private var scopeBinding: Binding<ContentSearchFeature.Scope> {
    Binding(get: { scope }, set: { onScopeChange($0) })
  }

  private var caseSensitiveBinding: Binding<Bool> {
    Binding(get: { caseSensitive }, set: { onCaseSensitiveChange($0) })
  }

  private var regexBinding: Binding<Bool> {
    Binding(get: { regex }, set: { onRegexChange($0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ContentSearchQuery(query: $query, isTextFieldFocused: isQueryFocused) { event in
        onEvent(event)
      }

      Divider()

      HStack(spacing: 8) {
        Picker("Search scope", selection: scopeBinding) {
          Text("Worktree").tag(ContentSearchFeature.Scope.worktree)
          Text("Global").tag(ContentSearchFeature.Scope.global)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Worktree searches the selected worktree; Global searches every local repository.")

        Spacer(minLength: 8)

        Toggle(isOn: caseSensitiveBinding) {
          Text("Aa")
            .font(.callout.monospaced())
        }
        .toggleStyle(.button)
        .help("Match case")

        Toggle(isOn: regexBinding) {
          Text(".*")
            .font(.callout.monospaced())
        }
        .toggleStyle(.button)
        .help("Use regular expression")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)

      Divider()

      ContentSearchList(
        rows: results,
        selectedIndex: $selectedIndex,
        scope: scope,
        hoveredID: $hoveredID
      ) { id in
        activate(id)
      }
    }
    .frame(maxWidth: 600)
    .background(
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        Rectangle()
          .fill(backgroundColor)
          .blendMode(.color)
      }
      .compositingGroup()
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
    )
    .shadow(radius: 32, x: 0, y: 12)
    .padding(Self.padding)
  }
}

private struct ContentSearchQuery: View {
  @Binding var query: String
  var onEvent: ((ContentSearchKeyboardEvent) -> Void)?
  @FocusState private var isTextFieldFocused: Bool

  init(
    query: Binding<String>,
    isTextFieldFocused: FocusState<Bool>,
    onEvent: ((ContentSearchKeyboardEvent) -> Void)? = nil
  ) {
    _query = query
    self.onEvent = onEvent
    _isTextFieldFocused = isTextFieldFocused
  }

  var body: some View {
    ZStack {
      Group {
        Button {
          onEvent?(.move(.up))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.upArrow, modifiers: [])
        Button {
          onEvent?(.move(.down))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.downArrow, modifiers: [])

        Button {
          onEvent?(.move(.up))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.init("p"), modifiers: [.control])
        Button {
          onEvent?(.move(.down))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.init("n"), modifiers: [.control])
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)

      TextField("Search in files...", text: $query)
        .padding()
        .font(.title3.weight(.light))
        .frame(height: ContentSearchCard.fieldHeight)
        .textFieldStyle(.plain)
        .focused($isTextFieldFocused)
        .onChange(of: isTextFieldFocused) { _, focused in
          if !focused {
            onEvent?(.exit)
          }
        }
        .onExitCommand { onEvent?(.exit) }
        .onMoveCommand { onEvent?(.move($0)) }
        .onSubmit { onEvent?(.submit) }
    }
  }
}

private struct ContentSearchList: View {
  static let listHeight: CGFloat = 320

  let rows: [ContentMatch]
  @Binding var selectedIndex: Int?
  let scope: ContentSearchFeature.Scope
  @Binding var hoveredID: ContentMatch.ID?
  let activate: (ContentMatch.ID) -> Void

  var body: some View {
    if rows.isEmpty {
      EmptyView()
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
              ContentSearchRowView(
                row: row,
                isSelected: isRowSelected(index: index),
                scope: scope,
                hoveredID: $hoveredID
              ) {
                activate(row.id)
              }
              .id(row.id)
            }
          }
          .padding(10)
        }
        .frame(height: Self.listHeight)
        .onChange(of: selectedIndex) { _, newValue in
          guard let selectedIndex = newValue, rows.indices.contains(selectedIndex) else { return }
          proxy.scrollTo(rows[selectedIndex].id)
        }
      }
    }
  }

  private func isRowSelected(index: Int) -> Bool {
    guard let selectedIndex else { return false }
    if selectedIndex < rows.count {
      return selectedIndex == index
    }
    return index == rows.count - 1
  }
}

private struct ContentSearchRowView: View {
  let row: ContentMatch
  let isSelected: Bool
  let scope: ContentSearchFeature.Scope
  @Binding var hoveredID: ContentMatch.ID?
  let activate: () -> Void

  /// Primary label: `relativePath:line`.
  private var locationLabel: String {
    "\(row.relativePath):\(row.line)"
  }

  /// In Global scope the location is repo-qualified so matches from different
  /// repositories are distinguishable; in Worktree scope it's just the path.
  private var subtitle: String? {
    switch scope {
    case .worktree:
      return nil
    case .global:
      return row.rootDisplayName
    }
  }

  /// The matched line with the matched span emphasized (bold). Falls back to a
  /// plain line when the range is empty or out of bounds.
  private var lineTextView: Text {
    let trimmed = trimmedLine
    guard let attributed = Self.emphasized(trimmed.text, matchRange: trimmed.range) else {
      return Text(trimmed.text)
    }
    return Text(attributed)
  }

  /// Leading-whitespace-trimmed line text + the adjusted match range, so deeply
  /// indented matches don't waste the row on indentation.
  private var trimmedLine: (text: String, range: NSRange) {
    let original = row.lineText
    let leadingCount = original.prefix(while: { $0 == " " || $0 == "\t" }).count
    guard leadingCount > 0 else { return (original, row.matchRange) }
    let trimmed = String(original.dropFirst(leadingCount))
    // The original range is in UTF-16 of `original`; leading whitespace here is
    // all ASCII, so the UTF-16 offset equals the character count.
    let newLocation = row.matchRange.location - leadingCount
    guard newLocation >= 0 else { return (trimmed, NSRange(location: 0, length: 0)) }
    return (trimmed, NSRange(location: newLocation, length: row.matchRange.length))
  }

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 8) {
        Image(systemName: "text.magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.subheadline.weight(.medium))
          .frame(width: 16, height: 16, alignment: .center)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          lineTextView
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.tail)

          HStack(spacing: 4) {
            Text(locationLabel)
              .lineLimit(1)
              .truncationMode(.middle)
            if let subtitle {
              Text("·")
              Text(subtitle)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(8)
      .contentShape(Rectangle())
      .transformEnvironment(\.colorScheme) { scheme in
        guard isSelected, scheme != .dark else { return }
        scheme = .dark
      }
      .background(rowBackground)
      .clipShape(.rect(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(locationLabel)
    .onHover { hovering in
      hoveredID = hovering ? row.id : nil
    }
  }

  private var rowBackground: some View {
    Group {
      if isSelected {
        Color(nsColor: .selectedContentBackgroundColor)
      } else if hoveredID == row.id {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      } else {
        Color.clear
      }
    }
  }

  /// Build an `AttributedString` that bolds the matched span. Returns `nil` when
  /// the range is empty or out of bounds (so the caller renders plain text).
  private static func emphasized(_ text: String, matchRange: NSRange) -> AttributedString? {
    guard matchRange.length > 0, NSMaxRange(matchRange) <= text.utf16.count else { return nil }
    var attributed = AttributedString(text)
    guard let swiftRange = Range(matchRange, in: text) else { return nil }
    guard let lower = AttributedString.Index(swiftRange.lowerBound, within: attributed),
      let upper = AttributedString.Index(swiftRange.upperBound, within: attributed)
    else { return nil }
    attributed[lower..<upper].font = .callout.monospaced().bold()
    attributed[lower..<upper].foregroundColor = .primary
    return attributed
  }
}
