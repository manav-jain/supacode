import Foundation
import Testing

@testable import supacode

/// Integration coverage for `FileDiffClient.liveValue` against a real temporary
/// git repository. Each test creates an isolated repo under the temp dir, runs
/// real `git`, and tears it down — no shared state, so the suite stays
/// non-flaky.
struct FileDiffClientTests {
  // MARK: - Helpers.

  /// Run `git` in `directory`, failing the test on a non-zero exit. Used only by
  /// the test fixtures (the client under test runs its own git).
  @discardableResult
  private static func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    // Pin identity + non-interactive so the test never depends on the host's git
    // config or prompts for anything.
    environment["GIT_AUTHOR_NAME"] = "Test"
    environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
    environment["GIT_COMMITTER_NAME"] = "Test"
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

  /// Create a fresh git repo in a unique temp directory and return its root.
  private static func makeRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "FileDiffClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], in: root)
    return root
  }

  // MARK: - A committed-then-modified file produces a parsed diff.

  @Test func diffReportsWorkingTreeChangeAgainstHead() async throws {
    let root = try Self.makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "hello.txt")
    try "line one\nline two\nline three\n".write(to: file, atomically: true, encoding: .utf8)
    try Self.git(["add", "hello.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "initial"], in: root)

    // Modify the middle line in the working tree (not committed).
    try "line one\nline TWO changed\nline three\n".write(to: file, atomically: true, encoding: .utf8)

    let diff = await FileDiffClient.liveValue.diff(file)

    let unwrapped = try #require(diff)
    #expect(!unwrapped.isEmpty)
    // The change touches the middle line: one removed, one added (plus context).
    let kinds = unwrapped.hunks.flatMap { $0.lines.map(\.kind) }
    #expect(kinds.contains(.removed))
    #expect(kinds.contains(.added))
    let addedTexts = unwrapped.hunks.flatMap { $0.lines }.filter { $0.kind == .added }.map(\.text)
    #expect(addedTexts.contains("line TWO changed"))
    let removedTexts = unwrapped.hunks.flatMap { $0.lines }.filter { $0.kind == .removed }.map(\.text)
    #expect(removedTexts.contains("line two"))
  }

  // MARK: - A committed, unmodified file has no diff.

  @Test func diffIsNilForUnmodifiedTrackedFile() async throws {
    let root = try Self.makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "clean.txt")
    try "unchanged\n".write(to: file, atomically: true, encoding: .utf8)
    try Self.git(["add", "clean.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "initial"], in: root)

    let diff = await FileDiffClient.liveValue.diff(file)

    #expect(diff == nil)
  }

  // MARK: - An untracked file has no diff against HEAD.

  @Test func diffIsNilForUntrackedFile() async throws {
    let root = try Self.makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    // Need at least one commit so HEAD exists; commit an unrelated file.
    let seed = root.appending(path: "seed.txt")
    try "seed\n".write(to: seed, atomically: true, encoding: .utf8)
    try Self.git(["add", "seed.txt"], in: root)
    try Self.git(["commit", "-q", "-m", "seed"], in: root)

    // A brand-new file that was never `git add`ed: untracked → no HEAD diff.
    let untracked = root.appending(path: "untracked.txt")
    try "brand new\n".write(to: untracked, atomically: true, encoding: .utf8)

    let diff = await FileDiffClient.liveValue.diff(untracked)

    #expect(diff == nil)
  }

  // MARK: - A file outside any git repo has no diff.

  @Test func diffIsNilForNonGitDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "FileDiffClientTests-nongit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "loose.txt")
    try "not in a repo\n".write(to: file, atomically: true, encoding: .utf8)

    let diff = await FileDiffClient.liveValue.diff(file)

    #expect(diff == nil)
  }
}
