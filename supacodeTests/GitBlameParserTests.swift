import Foundation
import Testing

@testable import supacode

/// Pure coverage for `FileBlame.Parser` — the `git blame` porcelain parser that
/// turns a porcelain stream into per-line attribution, with no git plumbing.
struct GitBlameParserTests {
  // MARK: - `--line-porcelain`: full header repeated per line.

  @Test func parsesLinePorcelainWithRepeatedHeaders() throws {
    // Two lines from two different commits. `--line-porcelain` repeats the full
    // metadata block for every line.
    let raw = """
      1111111111111111111111111111111111111111 1 1 1
      author Alice
      author-mail <alice@example.com>
      author-time 1700000000
      author-tz +0000
      committer Alice
      summary first commit
      filename hello.txt
      \tline one
      2222222222222222222222222222222222222222 2 2 1
      author Bob
      author-mail <bob@example.com>
      author-time 1700100000
      author-tz +0200
      committer Bob
      summary second commit
      filename hello.txt
      \tline two
      """

    let blame = FileBlame.Parser.parse(raw)

    #expect(blame.lines.count == 2)

    let first = try #require(blame.line(1))
    #expect(first.lineNumber == 1)
    #expect(first.commit == "11111111")
    #expect(first.author == "Alice")
    #expect(first.summary == "first commit")
    #expect(first.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(first.isUncommitted == false)

    let second = try #require(blame.line(2))
    #expect(second.commit == "22222222")
    #expect(second.author == "Bob")
    #expect(second.summary == "second commit")
  }

  // MARK: - `--porcelain`: metadata appears once, then referenced by SHA.

  @Test func parsesPorcelainWithReferencedCommit() throws {
    // The same commit touches lines 1 and 2; in plain `--porcelain` the metadata
    // block appears only the first time, and the second line's header references
    // the SHA with no following metadata.
    let raw = """
      abcabcabcabcabcabcabcabcabcabcabcabcabca 1 1 2
      author Carol
      author-time 1650000000
      author-tz +0000
      summary shared change
      filename foo.swift
      \tfirst line
      abcabcabcabcabcabcabcabcabcabcabcabcabca 2 2
      \tsecond line
      """

    let blame = FileBlame.Parser.parse(raw)

    #expect(blame.lines.count == 2)

    // Both lines must resolve to the same cached commit metadata.
    let first = try #require(blame.line(1))
    let second = try #require(blame.line(2))
    #expect(first.commit == "abcabcab")
    #expect(second.commit == "abcabcab")
    #expect(first.author == "Carol")
    #expect(second.author == "Carol")
    #expect(first.summary == "shared change")
    #expect(second.summary == "shared change")
  }

  // MARK: - Not-committed-yet pseudo-commit (all zeros) flags uncommitted.

  @Test func detectsUncommittedLine() throws {
    let raw = """
      0000000000000000000000000000000000000000 3 3 1
      author Not Committed Yet
      author-time 1700200000
      author-tz +0000
      summary Version of foo.swift from foo.swift
      filename foo.swift
      \tlocal edit
      """

    let blame = FileBlame.Parser.parse(raw)

    let line = try #require(blame.line(3))
    #expect(line.commit == "00000000")
    #expect(line.isUncommitted == true)
    #expect(line.author == "Not Committed Yet")
  }

  // MARK: - Empty input yields an empty blame.

  @Test func emptyInputYieldsEmpty() {
    #expect(FileBlame.Parser.parse("").isEmpty)
  }

  // MARK: - A summary containing spaces survives intact.

  @Test func summaryWithSpacesPreserved() throws {
    let raw = """
      deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 5 5 1
      author Dee
      author-time 1680000000
      author-tz +0000
      summary fix: handle the multi word summary case
      filename x.swift
      \tcontent
      """

    let blame = FileBlame.Parser.parse(raw)
    let line = try #require(blame.line(5))
    #expect(line.summary == "fix: handle the multi word summary case")
  }
}
