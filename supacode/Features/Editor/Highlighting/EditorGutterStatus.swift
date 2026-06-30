import Foundation

/// The per-line change classification the editor's git gutter strip draws beside
/// each line of the buffer (Phase 10). Computed purely from a `FileDiff` (working
/// tree vs HEAD), keyed by the *new-file* (working-tree) line number so it maps
/// directly onto the lines the editor is showing.
///
/// `nonisolated` (overriding the module's default main-actor isolation) so the
/// derivation can run wherever the diff result flows without an actor hop.
nonisolated enum EditorGutterChangeKind: Equatable, Sendable {
  /// A brand-new line with no HEAD counterpart.
  case added
  /// A line that replaced a HEAD line (a removed/added pair within the hunk).
  case modified
  /// One or more HEAD lines were deleted *above* this line; the gutter draws a
  /// small wedge at the top boundary of this line rather than filling it.
  case removedAbove
}

/// Pure, testable mapper from a parsed `FileDiff` to per-line change kinds. A
/// caseless enum (no top-level free funcs) so it is directly unit-testable
/// without any git plumbing or STTextView geometry.
nonisolated enum EditorGutterStatus {
  /// Derive `[newLineNumber: changeKind]` from `diff`.
  ///
  /// Within each hunk we treat the body as a sequence of runs. A maximal run of
  /// removed lines immediately followed by a run of added lines is a
  /// *replacement*: the first `min(removed, added)` added lines are `.modified`,
  /// any surplus added lines are `.added`. A run of added lines with no preceding
  /// removed run is `.added`. A run of removed lines with no following added run
  /// is a pure deletion: we tag the new-file line at the deletion boundary (the
  /// next line that still exists, or the last context line above if the deletion
  /// is at end-of-file) as `.removedAbove`.
  static func lineStatuses(for diff: FileDiff) -> [Int: EditorGutterChangeKind] {
    var result: [Int: EditorGutterChangeKind] = [:]

    for hunk in diff.hunks {
      // Removed lines in the current run that no added line has "consumed" yet.
      // An added line that follows a removed run is a replacement (`.modified`)
      // and consumes one pending removal; a removed line left pending at a
      // context line or end-of-hunk is a pure deletion.
      var pendingRemoved = 0
      // The last surviving new-file line number we saw (context or added), used to
      // anchor a trailing deletion marker when there's no following line.
      var lastNewLine = hunk.newStart - 1

      // Mark `line` as a pure-deletion boundary (a wedge) when it survives and
      // nothing stronger already classifies it.
      func markDeletionBoundary(_ line: Int?) {
        guard let line, line >= 1, result[line] == nil else { return }
        result[line] = .removedAbove
      }

      for line in hunk.lines {
        switch line.kind {
        case .context:
          // Any removed lines still pending at a surviving context line were a
          // pure deletion: anchor a wedge at this line.
          if pendingRemoved > 0 {
            markDeletionBoundary(line.newLineNumber)
          }
          pendingRemoved = 0
          if let newLine = line.newLineNumber {
            lastNewLine = newLine
          }

        case .removed:
          pendingRemoved += 1

        case .added:
          guard let newLine = line.newLineNumber else { continue }
          if pendingRemoved > 0 {
            // Replacing a removed line → modified.
            result[newLine] = .modified
            pendingRemoved -= 1
          } else {
            result[newLine] = .added
          }
          lastNewLine = newLine
        }
      }

      // End-of-hunk: a removed run never followed by adds/context is a trailing
      // deletion; anchor it on the last surviving line.
      if pendingRemoved > 0 {
        markDeletionBoundary(lastNewLine)
      }
    }

    return result
  }
}
