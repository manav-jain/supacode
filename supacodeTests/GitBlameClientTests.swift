import Foundation
import Testing

@testable import supacode

/// Integration coverage for `GitBlameClient.liveValue` against a real temporary
/// git repository. Each test builds an isolated repo, runs real `git`, and tears
/// it down — git identity + config are pinned so the suite stays non-flaky.
struct GitBlameClientTests {
  // MARK: - Helpers.

  @discardableResult
  private static func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_AUTHOR_NAME"] = "Test Author"
    environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
    environment["GIT_COMMITTER_NAME"] = "Test Author"
    environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let err = String(data: errData, encoding: .utf8) ?? ""
      Issue.record("git \(arguments.joined(separator: " ")) failed: \(err)")
    }
    return String(data: outData, encoding: .utf8) ?? ""
  }

  private static func makeRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "GitBlameClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], in: root)
    return root
  }

  // MARK: - Two commits attribute their lines to the right commits/authors.

  @Test func blameAttributesLinesToCommits() async throws {
    let root = try Self.makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "hello.txt")

    // Commit 1: a single line.
    try "first line\n".write(to: file, atomically: true, encoding: .utf8)
    try Self.git(["add", "hello.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "add first line"], in: root)

    // Commit 2: append a second line (line 1 stays attributed to commit 1).
    try "first line\nsecond line\n".write(to: file, atomically: true, encoding: .utf8)
    try Self.git(["add", "hello.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "add second line"], in: root)

    let blame = await GitBlameClient.liveValue.blame(file)

    let unwrapped = try #require(blame)
    #expect(unwrapped.lines.count == 2)

    let line1 = try #require(unwrapped.line(1))
    let line2 = try #require(unwrapped.line(2))

    // Both attributed to the same author, summaries match their commits.
    #expect(line1.author == "Test Author")
    #expect(line2.author == "Test Author")
    #expect(line1.summary == "add first line")
    #expect(line2.summary == "add second line")
    // Different commits touched the two lines.
    #expect(line1.commit != line2.commit)
    #expect(!line1.isUncommitted)
    #expect(!line2.isUncommitted)
    #expect(line1.timestamp != nil)
  }

  // MARK: - A working-tree edit blames to the not-committed-yet pseudo-commit.

  @Test func uncommittedEditBlamesToZeroCommit() async throws {
    let root = try Self.makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "wip.txt")

    try "committed line\n".write(to: file, atomically: true, encoding: .utf8)
    try Self.git(["add", "wip.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "initial"], in: root)

    // An uncommitted local addition.
    try "committed line\nuncommitted line\n".write(to: file, atomically: true, encoding: .utf8)

    let blame = await GitBlameClient.liveValue.blame(file)
    let unwrapped = try #require(blame)

    let line2 = try #require(unwrapped.line(2))
    #expect(line2.isUncommitted == true)
  }

  // MARK: - A file outside any git repo has no blame.

  @Test func blameIsNilForNonGitDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "GitBlameClientTests-nongit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "loose.txt")
    try "not in a repo\n".write(to: file, atomically: true, encoding: .utf8)

    let blame = await GitBlameClient.liveValue.blame(file)
    #expect(blame == nil)
  }
}
