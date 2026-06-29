import ComposableArchitecture
import Foundation
import SwiftUI

/// Quick-open file finder overlay (VS Code ⌘P style). Mirrors the visual
/// structure of `CommandPaletteOverlayView` — a centered `.ultraThinMaterial`
/// card with a query field, divider, and a scrollable results list — but renders
/// `FileSearchResult` rows. Self-contained: the small styling helpers are
/// duplicated rather than reaching into the palette's private types.
struct FileSearchOverlayView: View {
  @Bindable var store: StoreOf<FileSearchFeature>
  @FocusState private var isQueryFocused: Bool
  @State private var hoveredID: FileSearchResult.ID?

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
            .accessibilityLabel("Dismiss File Search")

          GeometryReader { geometry in
            let topOffset = max(
              0,
              geometry.size.height * 0.3
                - FileSearchCard.fieldHeight / 2
                - FileSearchCard.padding
            )
            VStack {
              FileSearchCard(
                query: $store.query,
                selectedIndex: $store.selectedIndex,
                results: store.results,
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

  private func activate(_ id: FileSearchResult.ID) {
    guard let result = store.results.first(where: { $0.id == id }) else { return }
    store.send(.activate(result))
  }
}

private enum FileSearchKeyboardEvent: Equatable {
  case exit
  case submit
  case move(MoveCommandDirection)
}

private struct FileSearchCard: View {
  static let padding: CGFloat = 16
  static let fieldHeight: CGFloat = 48

  @Binding var query: String
  @Binding var selectedIndex: Int?
  let results: [FileSearchResult]
  @Binding var hoveredID: FileSearchResult.ID?
  let isQueryFocused: FocusState<Bool>
  let onEvent: (FileSearchKeyboardEvent) -> Void
  let activate: (FileSearchResult.ID) -> Void

  private var backgroundColor: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      FileSearchQuery(query: $query, isTextFieldFocused: isQueryFocused) { event in
        onEvent(event)
      }

      Divider()

      FileSearchList(
        rows: results,
        selectedIndex: $selectedIndex,
        hoveredID: $hoveredID
      ) { id in
        activate(id)
      }
    }
    .frame(maxWidth: 500)
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

private struct FileSearchQuery: View {
  @Binding var query: String
  var onEvent: ((FileSearchKeyboardEvent) -> Void)?
  @FocusState private var isTextFieldFocused: Bool

  init(
    query: Binding<String>,
    isTextFieldFocused: FocusState<Bool>,
    onEvent: ((FileSearchKeyboardEvent) -> Void)? = nil
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

      TextField("Search files by name...", text: $query)
        .padding()
        .font(.title3.weight(.light))
        .frame(height: FileSearchCard.fieldHeight)
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

private struct FileSearchList: View {
  static let listHeight: CGFloat = 280

  let rows: [FileSearchResult]
  @Binding var selectedIndex: Int?
  @Binding var hoveredID: FileSearchResult.ID?
  let activate: (FileSearchResult.ID) -> Void

  var body: some View {
    if rows.isEmpty {
      EmptyView()
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
              FileSearchRowView(
                row: row,
                isSelected: isRowSelected(index: index),
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

private struct FileSearchRowView: View {
  let row: FileSearchResult
  let isSelected: Bool
  @Binding var hoveredID: FileSearchResult.ID?
  let activate: () -> Void

  private var title: String {
    (row.relativePath as NSString).lastPathComponent
  }

  private var subtitle: String? {
    let directory = (row.relativePath as NSString).deletingLastPathComponent
    return directory.isEmpty ? nil : directory
  }

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 8) {
        Image(systemName: "doc")
          .foregroundStyle(.secondary)
          .font(.subheadline.weight(.medium))
          .frame(width: 16, height: 16, alignment: .center)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.regular)
            .lineLimit(1)
            .truncationMode(.middle)

          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
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
    .help(row.relativePath)
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
}
