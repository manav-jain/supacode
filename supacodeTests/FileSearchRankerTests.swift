import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

struct FileSearchRankerTests {
  // MARK: - Enumeration.

  @Test func enumerationExcludesNoiseDirectories() throws {
    let url = try makeTempTree([
      "src/App.swift",
      "src/Helpers/Util.swift",
      "node_modules/left-pad/index.js",
      ".git/config",
      ".build/debug/binary",
      "README.md",
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let results = FileSearchRanker.enumerateFiles(root: makeRoot(url))
    let paths = Set(results.map(\.relativePath))

    #expect(paths.contains("src/App.swift"))
    #expect(paths.contains("src/Helpers/Util.swift"))
    #expect(paths.contains("README.md"))
    #expect(paths.contains { $0.contains("node_modules") } == false)
    #expect(paths.contains { $0.contains(".git") } == false)
    #expect(paths.contains { $0.contains(".build") } == false)
  }

  @Test func relativePathsAreRootRelative() throws {
    let url = try makeTempTree(["a/b/c.txt"])
    defer { try? FileManager.default.removeItem(at: url) }

    let results = FileSearchRanker.enumerateFiles(root: makeRoot(url))
    #expect(results.map(\.relativePath) == ["a/b/c.txt"])
    #expect(results.first?.absoluteURL.lastPathComponent == "c.txt")
  }

  @Test func enumerationTagsResultsWithRootIdentity() throws {
    let url = try makeTempTree(["a.txt"])
    defer { try? FileManager.default.removeItem(at: url) }

    let root = makeRoot(url, worktreeID: "/repo/main", displayName: "Repo / main")
    let results = FileSearchRanker.enumerateFiles(root: root)
    #expect(results.first?.worktreeID == WorktreeID("/repo/main"))
    #expect(results.first?.rootDisplayName == "Repo / main")
  }

  // MARK: - Empty query.

  @Test func emptyQueryReturnsCappedStableList() async throws {
    let url = try makeTempTree(["one.txt", "two.txt", "three.txt", "four.txt"])
    defer { try? FileManager.default.removeItem(at: url) }

    let capped = await FileSearchRanker.search(query: "", roots: [makeRoot(url)], maxResults: 2)
    #expect(capped.count == 2)

    let whitespaceOnly = await FileSearchRanker.search(query: "   ", roots: [makeRoot(url)], maxResults: 2)
    #expect(whitespaceOnly.count == 2)
  }

  @Test func zeroMaxResultsReturnsEmpty() async throws {
    let url = try makeTempTree(["a.txt"])
    defer { try? FileManager.default.removeItem(at: url) }

    let results = await FileSearchRanker.search(query: "a", roots: [makeRoot(url)], maxResults: 0)
    #expect(results.isEmpty)
  }

  @Test func emptyRootsReturnsEmpty() async {
    let results = await FileSearchRanker.search(query: "a", roots: [], maxResults: 10)
    #expect(results.isEmpty)
  }

  // MARK: - Ranking.

  @Test func prefixOutranksSubstringOutranksSubsequence() {
    let prefix = FileSearchRanker.score(query: "app", relativePath: "src/AppDelegate.swift")
    let substring = FileSearchRanker.score(query: "app", relativePath: "src/MyApp.swift")
    let subsequenceInBasename = FileSearchRanker.score(query: "ap", relativePath: "src/aXpY.swift")
    let pathSubsequence = FileSearchRanker.score(query: "sc", relativePath: "source/code.swift")

    #expect(prefix != nil)
    #expect(substring != nil)
    #expect(subsequenceInBasename != nil)
    #expect(pathSubsequence != nil)
    #expect((prefix ?? 0) > (substring ?? 0))
    #expect((substring ?? 0) > (subsequenceInBasename ?? 0))
    #expect((subsequenceInBasename ?? 0) > (pathSubsequence ?? 0))
  }

  @Test func nonMatchScoresNil() {
    #expect(FileSearchRanker.score(query: "zzz", relativePath: "src/App.swift") == nil)
  }

  @Test func searchRanksPrefixMatchFirst() async throws {
    let url = try makeTempTree([
      "deep/nested/contains-app-in-path.swift",
      "src/MyApp.swift",
      "AppDelegate.swift",
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let results = await FileSearchRanker.search(query: "app", roots: [makeRoot(url)], maxResults: 10)
    // Exact-prefix basename ("AppDelegate.swift") should rank ahead of the
    // basename-substring ("MyApp.swift"), which ranks ahead of the
    // path-subsequence-only match.
    #expect(results.first?.relativePath == "AppDelegate.swift")
    #expect(
      results.map(\.relativePath).firstIndex(of: "src/MyApp.swift")
        ?? .max < (results.map(\.relativePath).firstIndex(of: "deep/nested/contains-app-in-path.swift") ?? .max))
  }

  @Test func searchIsCaseInsensitive() async throws {
    let url = try makeTempTree(["README.md"])
    defer { try? FileManager.default.removeItem(at: url) }

    let results = await FileSearchRanker.search(query: "readme", roots: [makeRoot(url)], maxResults: 10)
    #expect(results.map(\.relativePath) == ["README.md"])
  }

  // MARK: - Multi-root (Global scope).

  @Test func searchMergesAndTagsAcrossRoots() async throws {
    let alpha = try makeTempTree(["alpha/App.swift"])
    let beta = try makeTempTree(["beta/App.swift"])
    defer {
      try? FileManager.default.removeItem(at: alpha)
      try? FileManager.default.removeItem(at: beta)
    }

    let roots = [
      makeRoot(alpha, worktreeID: "/alpha", displayName: "Alpha / main"),
      makeRoot(beta, worktreeID: "/beta", displayName: "Beta / main"),
    ]
    let results = await FileSearchRanker.search(query: "app", roots: roots, maxResults: 10)

    // Both roots' matches surface, tagged with their own root identity.
    #expect(results.count == 2)
    let byWorktree = Dictionary(grouping: results, by: \.worktreeID)
    #expect(byWorktree[WorktreeID("/alpha")]?.first?.rootDisplayName == "Alpha / main")
    #expect(byWorktree[WorktreeID("/beta")]?.first?.rootDisplayName == "Beta / main")
    // IDs stay unique across roots even though the relative path collides.
    #expect(Set(results.map(\.id)).count == 2)
  }

  @Test func searchRanksHoldAcrossRoots() async throws {
    let alpha = try makeTempTree(["src/contains-app-in-path.swift"])
    let beta = try makeTempTree(["AppDelegate.swift"])
    defer {
      try? FileManager.default.removeItem(at: alpha)
      try? FileManager.default.removeItem(at: beta)
    }

    let roots = [
      makeRoot(alpha, worktreeID: "/alpha", displayName: "Alpha"),
      makeRoot(beta, worktreeID: "/beta", displayName: "Beta"),
    ]
    let results = await FileSearchRanker.search(query: "app", roots: roots, maxResults: 10)
    // The exact-prefix basename in the SECOND root outranks the path-subsequence
    // match in the first — ranking is over the merged set, not per-root.
    #expect(results.first?.relativePath == "AppDelegate.swift")
    #expect(results.first?.worktreeID == WorktreeID("/beta"))
  }

  @Test func globalCapBoundsMergedResults() async throws {
    let alpha = try makeTempTree(["a1.txt", "a2.txt", "a3.txt"])
    let beta = try makeTempTree(["b1.txt", "b2.txt", "b3.txt"])
    defer {
      try? FileManager.default.removeItem(at: alpha)
      try? FileManager.default.removeItem(at: beta)
    }

    let roots = [
      makeRoot(alpha, worktreeID: "/alpha", displayName: "Alpha"),
      makeRoot(beta, worktreeID: "/beta", displayName: "Beta"),
    ]
    // Six candidates across two roots, capped to 4.
    let results = await FileSearchRanker.search(query: "", roots: roots, maxResults: 4)
    #expect(results.count == 4)
  }

  // MARK: - Subsequence helper.

  @Test func subsequenceMatching() {
    #expect(FileSearchRanker.isSubsequence("abc", of: "axbxcx"))
    #expect(FileSearchRanker.isSubsequence("abc", of: "cba") == false)
    #expect(FileSearchRanker.isSubsequence("", of: "anything"))
    #expect(FileSearchRanker.isSubsequence("abc", of: "ab") == false)
  }

  // MARK: - Helpers.

  private func makeRoot(
    _ url: URL,
    worktreeID: String = "/repo",
    displayName: String = "Repo"
  ) -> FileSearchRoot {
    FileSearchRoot(worktreeID: WorktreeID(worktreeID), url: url, displayName: displayName)
  }

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
