import Foundation
import Testing

@testable import supacode

struct FileDiffParserTests {
  // MARK: - Multi-hunk diff with added / removed / context lines.

  @Test func parsesMultipleHunksWithLineNumbers() {
    let raw = """
      diff --git a/Sources/Foo.swift b/Sources/Foo.swift
      index 1234567..89abcde 100644
      --- a/Sources/Foo.swift
      +++ b/Sources/Foo.swift
      @@ -1,4 +1,5 @@ struct Foo {
       struct Foo {
      -  let value = 1
      +  let value = 2
      +  let extra = 3
         func bar() {}
      @@ -10,2 +11,2 @@
       // tail context
      -  old tail
      +  new tail
      """

    let diff = FileDiff.Parser.parse(raw)

    #expect(diff.hunks.count == 2)

    let first = diff.hunks[0]
    #expect(first.header == "@@ -1,4 +1,5 @@ struct Foo {")
    #expect(first.oldStart == 1)
    #expect(first.oldCount == 4)
    #expect(first.newStart == 1)
    #expect(first.newCount == 5)
    #expect(first.lines.map(\.kind) == [.context, .removed, .added, .added, .context])
    #expect(
      first.lines.map(\.text) == [
        "struct Foo {", "  let value = 1", "  let value = 2", "  let extra = 3", "  func bar() {}",
      ])

    // Line-number tracking across mixed kinds.
    let context0 = first.lines[0]
    #expect(context0.oldLineNumber == 1)
    #expect(context0.newLineNumber == 1)

    let removed = first.lines[1]
    #expect(removed.oldLineNumber == 2)
    #expect(removed.newLineNumber == nil)

    let added1 = first.lines[2]
    #expect(added1.oldLineNumber == nil)
    #expect(added1.newLineNumber == 2)

    let added2 = first.lines[3]
    #expect(added2.oldLineNumber == nil)
    #expect(added2.newLineNumber == 3)

    // After one removed (old advances) and two added (new advances), the trailing
    // context line is old 3 / new 4.
    let context1 = first.lines[4]
    #expect(context1.oldLineNumber == 3)
    #expect(context1.newLineNumber == 4)

    let second = diff.hunks[1]
    #expect(second.oldStart == 10)
    #expect(second.newStart == 11)
    #expect(second.lines.map(\.kind) == [.context, .removed, .added])
    #expect(second.id == 1)
  }

  // MARK: - Hunk header with omitted counts defaults each to 1.

  @Test func defaultsOmittedCountsToOne() {
    let raw = """
      @@ -5 +5 @@
      -was
      +now
      """

    let diff = FileDiff.Parser.parse(raw)

    #expect(diff.hunks.count == 1)
    let hunk = diff.hunks[0]
    #expect(hunk.oldStart == 5)
    #expect(hunk.oldCount == 1)
    #expect(hunk.newStart == 5)
    #expect(hunk.newCount == 1)
    #expect(hunk.lines.map(\.kind) == [.removed, .added])
  }

  // MARK: - New-file diff (all added, old start 0).

  @Test func parsesNewFileDiff() {
    let raw = """
      diff --git a/New.txt b/New.txt
      new file mode 100644
      index 0000000..e69de29
      --- /dev/null
      +++ b/New.txt
      @@ -0,0 +1,3 @@
      +line one
      +line two
      +line three
      """

    let diff = FileDiff.Parser.parse(raw)

    #expect(diff.hunks.count == 1)
    let hunk = diff.hunks[0]
    #expect(hunk.oldStart == 0)
    #expect(hunk.oldCount == 0)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 3)
    #expect(hunk.lines.allSatisfy { $0.kind == .added })
    #expect(hunk.lines.map(\.newLineNumber) == [1, 2, 3])
    #expect(hunk.lines.map(\.oldLineNumber) == [nil, nil, nil])
  }

  // MARK: - "No newline at end of file" sentinel is dropped, not rendered.

  @Test func dropsNoNewlineSentinel() {
    let raw = """
      @@ -1,1 +1,1 @@
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """

    let diff = FileDiff.Parser.parse(raw)

    #expect(diff.hunks.count == 1)
    #expect(diff.hunks[0].lines.map(\.kind) == [.removed, .added])
    #expect(diff.hunks[0].lines.map(\.text) == ["old", "new"])
  }

  // MARK: - Blank context line is preserved (empty text, context kind).

  @Test func preservesBlankContextLine() {
    // A blank unchanged line is " " in the diff (just the leading space marker).
    let raw = "@@ -1,3 +1,3 @@\n a\n \n+inserted\n c"

    let diff = FileDiff.Parser.parse(raw)

    #expect(diff.hunks.count == 1)
    let lines = diff.hunks[0].lines
    #expect(lines.map(\.kind) == [.context, .context, .added, .context])
    #expect(lines[1].text == "")
    #expect(lines[1].oldLineNumber == 2)
    #expect(lines[1].newLineNumber == 2)
  }

  // MARK: - Empty output → empty diff.

  @Test func emptyOutputYieldsEmptyDiff() {
    #expect(FileDiff.Parser.parse("").hunks.isEmpty)
    #expect(FileDiff.Parser.parse("\n").hunks.isEmpty)
    #expect(FileDiff.Parser.parse("").isEmpty)
  }

  // MARK: - Header-only output (no hunks) → empty diff.

  @Test func headerOnlyYieldsEmptyDiff() {
    let raw = """
      diff --git a/Foo.swift b/Foo.swift
      index 1234567..89abcde 100644
      --- a/Foo.swift
      +++ b/Foo.swift
      """

    #expect(FileDiff.Parser.parse(raw).isEmpty)
  }
}
