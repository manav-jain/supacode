import SwiftUI

/// Read-only renderer for a parsed `FileDiff` (working tree vs HEAD), shown in
/// place of the editable text when the editor's diff mode is on (Phase 9). Each
/// hunk renders its `@@ … @@` header in secondary style, then one row per line
/// with an old / new line-number gutter, a `+` / `-` / ` ` marker, and the
/// monospaced text — added lines green-tinted, removed lines red-tinted, using
/// semantic system colors. Shows an empty state when there's nothing to diff.
struct DiffView: View {
  /// The parsed diff, or `nil` when there are no changes / the file isn't
  /// tracked / isn't in a repo.
  let diff: FileDiff?
  /// True while the diff is being computed, to distinguish "loading" from "no
  /// changes" (both have a `nil` diff).
  var isLoading: Bool = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff, !diff.isEmpty {
        diffList(diff)
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private func diffList(_ diff: FileDiff) -> some View {
    ScrollView([.vertical, .horizontal]) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(diff.hunks) { hunk in
          hunkHeader(hunk)
          ForEach(hunk.lines) { line in
            DiffLineRow(line: line)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func hunkHeader(_ hunk: DiffHunk) -> some View {
    Text(hunk.header)
      .font(.callout.monospaced())
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.quaternary)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Changes", systemImage: "equal.circle")
    } description: {
      Text("This file matches HEAD, or it isn't tracked by git.")
    }
  }
}

/// One diff line: line-number gutter, marker, and text, tinted by kind.
private struct DiffLineRow: View {
  let line: DiffLine

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      gutter(line.oldLineNumber)
      gutter(line.newLineNumber)
      Text(marker)
        .frame(width: 10, alignment: .center)
        .foregroundStyle(.secondary)
      Text(line.text.isEmpty ? " " : line.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.body.monospaced())
    .padding(.horizontal, 8)
    .padding(.vertical, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(background)
  }

  private func gutter(_ number: Int?) -> some View {
    Text(number.map(String.init) ?? "")
      .font(.callout.monospacedDigit())
      .foregroundStyle(.tertiary)
      .frame(width: 44, alignment: .trailing)
  }

  private var marker: String {
    switch line.kind {
    case .added: "+"
    case .removed: "-"
    case .context: " "
    }
  }

  private var background: Color {
    switch line.kind {
    case .added: .green.opacity(0.15)
    case .removed: .red.opacity(0.15)
    case .context: .clear
    }
  }
}

#Preview("Diff") {
  DiffView(
    diff: FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,4 +1,5 @@ struct Example {",
        oldStart: 1,
        oldCount: 4,
        newStart: 1,
        newCount: 5,
        lines: [
          DiffLine(id: 0, kind: .context, text: "struct Example {", oldLineNumber: 1, newLineNumber: 1),
          DiffLine(id: 1, kind: .removed, text: "  let value = 1", oldLineNumber: 2, newLineNumber: nil),
          DiffLine(id: 2, kind: .added, text: "  let value = 2", oldLineNumber: nil, newLineNumber: 2),
          DiffLine(id: 3, kind: .added, text: "  let extra = 3", oldLineNumber: nil, newLineNumber: 3),
          DiffLine(id: 4, kind: .context, text: "}", oldLineNumber: 3, newLineNumber: 4),
        ]
      )
    ])
  )
  .frame(width: 480, height: 320)
}

#Preview("No changes") {
  DiffView(diff: nil)
    .frame(width: 480, height: 320)
}
