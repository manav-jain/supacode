import Foundation
import Testing

@testable import supacode

struct FileSearchRankerTests {
  // MARK: - Enumeration.

  @Test func enumerationExcludesNoiseDirectories() throws {
    let root = try makeTempTree([
      "src/App.swift",
      "src/Helpers/Util.swift",
      "node_modules/left-pad/index.js",
      ".git/config",
      ".build/debug/binary",
      "README.md",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let results = FileSearchRanker.enumerateFiles(root: root)
    let paths = Set(results.map(\.relativePath))

    #expect(paths.contains("src/App.swift"))
    #expect(paths.contains("src/Helpers/Util.swift"))
    #expect(paths.contains("README.md"))
    #expect(paths.contains { $0.contains("node_modules") } == false)
    #expect(paths.contains { $0.contains(".git") } == false)
    #expect(paths.contains { $0.contains(".build") } == false)
  }

  @Test func relativePathsAreRootRelative() throws {
    let root = try makeTempTree(["a/b/c.txt"])
    defer { try? FileManager.default.removeItem(at: root) }

    let results = FileSearchRanker.enumerateFiles(root: root)
    #expect(results.map(\.relativePath) == ["a/b/c.txt"])
    #expect(results.first?.absoluteURL.lastPathComponent == "c.txt")
  }

  // MARK: - Empty query.

  @Test func emptyQueryReturnsCappedStableList() throws {
    let root = try makeTempTree(["one.txt", "two.txt", "three.txt", "four.txt"])
    defer { try? FileManager.default.removeItem(at: root) }

    let capped = FileSearchRanker.search(query: "", root: root, maxResults: 2)
    #expect(capped.count == 2)

    let whitespaceOnly = FileSearchRanker.search(query: "   ", root: root, maxResults: 2)
    #expect(whitespaceOnly.count == 2)
  }

  @Test func zeroMaxResultsReturnsEmpty() throws {
    let root = try makeTempTree(["a.txt"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(FileSearchRanker.search(query: "a", root: root, maxResults: 0).isEmpty)
  }

  // MARK: - Ranking.

  @Test func prefixOutranksSubstringOutranksSubsequence() {
    let prefix = FileSearchRanker.score(query: "app", relativePath: "src/AppDelegate.swift")
    let substring = FileSearchRanker.score(query: "app", relativePath: "src/MyApp.swift")
    let subsequenceInBasename = FileSearchRanker.score(query: "ap", relativePath: "src/aXpY.swift")
    let pathSubsequence = FileSearchRanker.score(query: "sc", relativePath: "source/code.swift")

    let prefixScore = try? #require(prefix)
    let substringScore = try? #require(substring)

    #expect(prefix != nil)
    #expect(substring != nil)
    #expect(subsequenceInBasename != nil)
    #expect(pathSubsequence != nil)
    #expect((prefixScore ?? 0) > (substringScore ?? 0))
    #expect((substring ?? 0) > (subsequenceInBasename ?? 0))
    #expect((subsequenceInBasename ?? 0) > (pathSubsequence ?? 0))
  }

  @Test func nonMatchScoresNil() {
    #expect(FileSearchRanker.score(query: "zzz", relativePath: "src/App.swift") == nil)
  }

  @Test func searchRanksPrefixMatchFirst() throws {
    let root = try makeTempTree([
      "deep/nested/contains-app-in-path.swift",
      "src/MyApp.swift",
      "AppDelegate.swift",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let results = FileSearchRanker.search(query: "app", root: root, maxResults: 10)
    // Exact-prefix basename ("AppDelegate.swift") should rank ahead of the
    // basename-substring ("MyApp.swift"), which ranks ahead of the
    // path-subsequence-only match.
    #expect(results.first?.relativePath == "AppDelegate.swift")
    #expect(
      results.map(\.relativePath).firstIndex(of: "src/MyApp.swift")
        ?? .max < (results.map(\.relativePath).firstIndex(of: "deep/nested/contains-app-in-path.swift") ?? .max))
  }

  @Test func searchIsCaseInsensitive() throws {
    let root = try makeTempTree(["README.md"])
    defer { try? FileManager.default.removeItem(at: root) }

    let results = FileSearchRanker.search(query: "readme", root: root, maxResults: 10)
    #expect(results.map(\.relativePath) == ["README.md"])
  }

  // MARK: - Subsequence helper.

  @Test func subsequenceMatching() {
    #expect(FileSearchRanker.isSubsequence("abc", of: "axbxcx"))
    #expect(FileSearchRanker.isSubsequence("abc", of: "cba") == false)
    #expect(FileSearchRanker.isSubsequence("", of: "anything"))
    #expect(FileSearchRanker.isSubsequence("abc", of: "ab") == false)
  }

  // MARK: - Helpers.

  private func makeTempTree(_ relativePaths: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "FileSearchRankerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    for relativePath in relativePaths {
      let fileURL = root.appending(path: relativePath)
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("x".utf8).write(to: fileURL)
    }
    return root
  }
}
