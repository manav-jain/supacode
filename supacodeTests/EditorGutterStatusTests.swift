import Foundation
import Testing

@testable import supacode

/// Pure coverage for `EditorGutterStatus.lineStatuses(for:)` — the FileDiff →
/// per-new-line change-kind mapper that drives the editor's git gutter strip.
struct EditorGutterStatusTests {
  /// Build a `DiffLine` quickly for fixtures.
  private static func line(_ id: Int, _ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) -> DiffLine {
    DiffLine(id: id, kind: kind, text: text, oldLineNumber: old, newLineNumber: new)
  }

  // MARK: - A modified line (removed+added pair) is `.modified`.

  @Test func removedThenAddedIsModified() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,3 +1,3 @@",
        oldStart: 1,
        oldCount: 3,
        newStart: 1,
        newCount: 3,
        lines: [
          Self.line(0, .context, "one", old: 1, new: 1),
          Self.line(1, .removed, "two", old: 2, new: nil),
          Self.line(2, .added, "two changed", old: nil, new: 2),
          Self.line(3, .context, "three", old: 3, new: 3),
        ]
      )
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    #expect(status[2] == .modified)
    #expect(status[1] == nil)
    #expect(status[3] == nil)
  }

  // MARK: - A pure addition (no preceding removed) is `.added`.

  @Test func addedWithoutRemovedIsAdded() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,2 +1,4 @@",
        oldStart: 1,
        oldCount: 2,
        newStart: 1,
        newCount: 4,
        lines: [
          Self.line(0, .context, "one", old: 1, new: 1),
          Self.line(1, .added, "new a", old: nil, new: 2),
          Self.line(2, .added, "new b", old: nil, new: 3),
          Self.line(3, .context, "two", old: 2, new: 4),
        ]
      )
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    #expect(status[2] == .added)
    #expect(status[3] == .added)
    #expect(status[1] == nil)
    #expect(status[4] == nil)
  }

  // MARK: - A replacement with surplus adds: first is modified, rest are added.

  @Test func replacementWithSurplusAddsSplitsModifiedAndAdded() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,2 +1,4 @@",
        oldStart: 1,
        oldCount: 2,
        newStart: 1,
        newCount: 4,
        lines: [
          // One removed, three added → first added is .modified, next two .added.
          Self.line(0, .removed, "old", old: 1, new: nil),
          Self.line(1, .added, "a", old: nil, new: 1),
          Self.line(2, .added, "b", old: nil, new: 2),
          Self.line(3, .added, "c", old: nil, new: 3),
        ]
      )
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    #expect(status[1] == .modified)
    #expect(status[2] == .added)
    #expect(status[3] == .added)
  }

  // MARK: - A pure deletion marks the surviving boundary line `.removedAbove`.

  @Test func pureDeletionMarksBoundaryLine() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,4 +1,2 @@",
        oldStart: 1,
        oldCount: 4,
        newStart: 1,
        newCount: 2,
        lines: [
          Self.line(0, .context, "one", old: 1, new: 1),
          Self.line(1, .removed, "two", old: 2, new: nil),
          Self.line(2, .removed, "three", old: 3, new: nil),
          // The next surviving new-file line is line 2 ("four"): deletion boundary.
          Self.line(3, .context, "four", old: 4, new: 2),
        ]
      )
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    #expect(status[2] == .removedAbove)
    #expect(status[1] == nil)
  }

  // MARK: - A trailing deletion at EOF anchors on the last surviving line.

  @Test func trailingDeletionAnchorsOnLastLine() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,3 +1,1 @@",
        oldStart: 1,
        oldCount: 3,
        newStart: 1,
        newCount: 1,
        lines: [
          Self.line(0, .context, "keep", old: 1, new: 1),
          Self.line(1, .removed, "gone a", old: 2, new: nil),
          Self.line(2, .removed, "gone b", old: 3, new: nil),
        ]
      )
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    // No surviving line follows the deletion, so it anchors on line 1.
    #expect(status[1] == .removedAbove)
  }

  // MARK: - Multiple hunks accumulate independently.

  @Test func multipleHunksAccumulate() {
    let diff = FileDiff(hunks: [
      DiffHunk(
        id: 0,
        header: "@@ -1,1 +1,2 @@",
        oldStart: 1,
        oldCount: 1,
        newStart: 1,
        newCount: 2,
        lines: [
          Self.line(0, .context, "a", old: 1, new: 1),
          Self.line(1, .added, "b", old: nil, new: 2),
        ]
      ),
      DiffHunk(
        id: 1,
        header: "@@ -10,1 +11,1 @@",
        oldStart: 10,
        oldCount: 1,
        newStart: 11,
        newCount: 1,
        lines: [
          Self.line(0, .removed, "old", old: 10, new: nil),
          Self.line(1, .added, "new", old: nil, new: 11),
        ]
      ),
    ])

    let status = EditorGutterStatus.lineStatuses(for: diff)

    #expect(status[2] == .added)
    #expect(status[11] == .modified)
  }

  // MARK: - An empty diff yields no statuses.

  @Test func emptyDiffYieldsEmpty() {
    #expect(EditorGutterStatus.lineStatuses(for: FileDiff(hunks: [])).isEmpty)
  }
}
