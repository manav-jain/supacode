import Foundation
import Testing

@testable import supacode

struct ContentSearchEngineTests {
  // MARK: - Basic matching (Swift fallback engine).

  @Test func matchesLineNumbersAndText() async throws {
    let url = try makeTempTree([
      "main.swift": """
      import Foundation
      let answer = 42
      print(answer)
      """
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let matches = await ContentSearchEngine.search(
      query: "answer",
      roots: [makeRoot(url)],
      options: .init(),
      maxResults: 100
    )
    // "answer" appears on line 2 (declaration) and line 3 (print).
    #expect(matches.count == 2)
    let byLine = Dictionary(grouping: matches, by: \.line)
    #expect(byLine[2]?.first?.lineText == "let answer = 42")
    #expect(byLine[3]?.first?.lineText == "print(answer)")
    // The match range points at "answer" within the line text.
    let line2 = try #require(byLine[2]?.first)
    let nsText = line2.lineText as NSString
    #expect(nsText.substring(with: line2.matchRange) == "answer")
  }

  @Test func relativePathAndFileURLAreCorrect() async throws {
    let url = try makeTempTree(["src/Deep/File.swift": "needle here"])
    defer { try? FileManager.default.removeItem(at: url) }

    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: [makeRoot(url)],
      options: .init(),
      maxResults: 100
    )
    let match = try #require(matches.first)
    #expect(match.relativePath == "src/Deep/File.swift")
    #expect(match.line == 1)
    #expect(match.fileURL.lastPathComponent == "File.swift")
  }

  // MARK: - Case sensitivity.

  @Test func caseInsensitiveByDefault() async throws {
    let url = try makeTempTree(["a.txt": "Hello WORLD"])
    defer { try? FileManager.default.removeItem(at: url) }

    let insensitive = await ContentSearchEngine.search(
      query: "world",
      roots: [makeRoot(url)],
      options: .init(caseSensitive: false),
      maxResults: 100
    )
    #expect(insensitive.count == 1)

    let sensitive = await ContentSearchEngine.search(
      query: "world",
      roots: [makeRoot(url)],
      options: .init(caseSensitive: true),
      maxResults: 100
    )
    #expect(sensitive.isEmpty)
  }

  // MARK: - Regex.

  @Test func regexMatchesPattern() async throws {
    let url = try makeTempTree(["nums.txt": "value = 1234\nname = foo"])
    defer { try? FileManager.default.removeItem(at: url) }

    let matches = await ContentSearchEngine.search(
      query: "[0-9]+",
      roots: [makeRoot(url)],
      options: .init(regex: true),
      maxResults: 100
    )
    #expect(matches.count == 1)
    #expect(matches.first?.line == 1)
    let match = try #require(matches.first)
    let nsText = match.lineText as NSString
    #expect(nsText.substring(with: match.matchRange) == "1234")
  }

  // MARK: - Binary / large-file skip.

  @Test func skipsBinaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ContentSearchBinary-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A file whose head contains a NUL byte should be treated as binary + skipped,
    // even though "needle" appears in it as UTF-8 bytes.
    var bytes = Data([0x00, 0x01, 0x02])
    bytes.append(Data("needle".utf8))
    try bytes.write(to: root.appending(path: "blob.bin"))
    try Data("needle".utf8).write(to: root.appending(path: "text.txt"))

    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: [makeRoot(root)],
      options: .init(),
      maxResults: 100
    )
    // Only the text file matches; the binary blob is skipped.
    #expect(matches.count == 1)
    #expect(matches.first?.relativePath == "text.txt")
  }

  @Test func skipsLargeFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ContentSearchLarge-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Build a file larger than the cap whose last line contains the query.
    var large = String(repeating: "x\n", count: 2 * 1024 * 1024)
    large += "needle\n"
    try Data(large.utf8).write(to: root.appending(path: "big.txt"))
    try Data("needle".utf8).write(to: root.appending(path: "small.txt"))

    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: [makeRoot(root)],
      options: .init(),
      maxResults: 100
    )
    // The oversized file is skipped; only the small file matches.
    #expect(matches.count == 1)
    #expect(matches.first?.relativePath == "small.txt")
  }

  // MARK: - Noise-directory exclusion.

  @Test func excludesNoiseDirectories() async throws {
    let url = try makeTempTree([
      "src/App.swift": "needle",
      "node_modules/pkg/index.js": "needle",
      ".git/config": "needle",
      ".build/out.txt": "needle",
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: [makeRoot(url)],
      options: .init(),
      maxResults: 100
    )
    #expect(matches.count == 1)
    #expect(matches.first?.relativePath == "src/App.swift")
  }

  // MARK: - Multi-root tagging.

  @Test func tagsMatchesAcrossRoots() async throws {
    let alpha = try makeTempTree(["a.txt": "needle"])
    let beta = try makeTempTree(["b.txt": "needle"])
    defer {
      try? FileManager.default.removeItem(at: alpha)
      try? FileManager.default.removeItem(at: beta)
    }

    let roots = [
      makeRoot(alpha, worktreeID: "/alpha", displayName: "Alpha / main"),
      makeRoot(beta, worktreeID: "/beta", displayName: "Beta / main"),
    ]
    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: roots,
      options: .init(),
      maxResults: 100
    )
    #expect(matches.count == 2)
    let byWorktree = Dictionary(grouping: matches, by: \.worktreeID)
    #expect(byWorktree[WorktreeID("/alpha")]?.first?.rootDisplayName == "Alpha / main")
    #expect(byWorktree[WorktreeID("/beta")]?.first?.rootDisplayName == "Beta / main")
    // IDs stay unique across roots even when paths/lines collide.
    #expect(Set(matches.map(\.id)).count == 2)
  }

  // MARK: - Caps.

  @Test func respectsMaxResultsCap() async throws {
    let url = try makeTempTree([
      "a.txt": "needle\nneedle\nneedle\nneedle\nneedle"
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let matches = await ContentSearchEngine.search(
      query: "needle",
      roots: [makeRoot(url)],
      options: .init(),
      maxResults: 3
    )
    #expect(matches.count == 3)
  }

  @Test func emptyQueryReturnsNothing() async throws {
    let url = try makeTempTree(["a.txt": "needle"])
    defer { try? FileManager.default.removeItem(at: url) }

    let blank = await ContentSearchEngine.search(
      query: "   ",
      roots: [makeRoot(url)],
      options: .init(),
      maxResults: 100
    )
    #expect(blank.isEmpty)
  }

  // MARK: - git grep line parsing (pure).

  @Test func parsesGitGrepLines() {
    let output = "src/App.swift:42:    let answer = 42\nREADME.md:1:# Title needle"
    let root = makeRoot(URL(fileURLWithPath: "/repo"), worktreeID: "/repo", displayName: "Repo")
    let matches = ContentSearchEngine.parseGitGrep(
      output,
      root: root,
      query: "needle",
      options: .init(),
      maxResults: 100
    )
    #expect(matches.count == 2)
    #expect(matches[0].relativePath == "src/App.swift")
    #expect(matches[0].line == 42)
    #expect(matches[0].lineText == "    let answer = 42")
    #expect(matches[1].relativePath == "README.md")
    #expect(matches[1].line == 1)
  }

  @Test func splitsGitGrepLineWithColonsInText() {
    // The matched text itself contains colons; only the path:line: prefix counts.
    let parsed = ContentSearchEngine.splitGitGrepLine("path/file.swift:10:let url = \"http://x\"")
    #expect(parsed?.path == "path/file.swift")
    #expect(parsed?.line == 10)
    #expect(parsed?.text == "let url = \"http://x\"")
  }

  // MARK: - Match-range computation.

  @Test func firstMatchRangeFixedString() {
    let range = ContentSearchEngine.firstMatchRange(
      of: "bar",
      in: "foo bar baz",
      options: .init()
    )
    #expect(range == NSRange(location: 4, length: 3))
  }

  // MARK: - git grep engine (real temp repo).

  @Test func gitGrepSearchesTrackedFiles() async throws {
    guard let gitURL = Self.gitExecutableURL() else { return }  // skip if no git
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ContentSearchGit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("let answer = 42\nprint(answer)\n".utf8).write(to: root.appending(path: "main.swift"))
    try Data("untracked needle\n".utf8).write(to: root.appending(path: "untracked.txt"))

    try await Self.runGit(gitURL, ["init", "-q"], in: root)
    try await Self.runGit(gitURL, ["config", "user.email", "t@t.test"], in: root)
    try await Self.runGit(gitURL, ["config", "user.name", "Test"], in: root)
    try await Self.runGit(gitURL, ["add", "main.swift"], in: root)
    try await Self.runGit(gitURL, ["commit", "-q", "-m", "init"], in: root)

    let root2 = ContentSearchRoot(
      worktreeID: WorktreeID(root.path),
      url: root,
      displayName: "Repo",
      isGitRepository: true
    )
    let matches = await ContentSearchEngine.searchRoot(
      query: "answer",
      root: root2,
      options: .init(),
      maxResults: 100
    )
    // git grep finds both occurrences in the tracked file.
    #expect(matches.count == 2)
    #expect(Set(matches.map(\.line)) == [1, 2])
    #expect(matches.allSatisfy { $0.relativePath == "main.swift" })
  }

  private static func gitExecutableURL() -> URL? {
    let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    return nil
  }

  private static func runGit(_ gitURL: URL, _ arguments: [String], in directory: URL) async throws {
    _ = try await ContentSearchEngine.runProcess(
      executableURL: gitURL,
      arguments: arguments,
      currentDirectoryURL: directory
    )
  }

  // MARK: - Helpers.

  private func makeRoot(
    _ url: URL,
    worktreeID: String = "/repo",
    displayName: String = "Repo"
  ) -> ContentSearchRoot {
    // isGitRepository false so the engine takes the deterministic Swift walk
    // (no dependency on a real git binary / repo).
    ContentSearchRoot(
      worktreeID: WorktreeID(worktreeID),
      url: url,
      displayName: displayName,
      isGitRepository: false
    )
  }

  private func makeTempTree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ContentSearchEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    for (relativePath, contents) in files {
      let fileURL = root.appending(path: relativePath)
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(contents.utf8).write(to: fileURL)
    }
    return root
  }
}
