import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let gitBlameLogger = SupaLogger("GitBlameClient")

/// Computes `git blame` attribution for a single file for the in-app editor's
/// inline-blame feature (Phase 10). Mirrors `FileDiffClient`'s dependency shape:
/// a struct of `@Sendable` closures plus a `DependencyKey` conformance so
/// reducers inject a stub in tests. Gated upstream behind `FeatureFlag.editorView`
/// — nothing here touches the flag because the only caller (the editor feature)
/// is itself reachable only when the flag is on.
struct GitBlameClient: Sendable {
  /// Blame every line of `fileURL`. Returns `nil` when the file isn't in a git
  /// repo, is untracked, or git fails — i.e. there is nothing to attribute.
  /// Never throws: a non-repo / git failure is just "no blame".
  var blame: @Sendable (_ fileURL: URL) async -> FileBlame?
}

/// Per-line `git blame` attribution for one file. Empty `lines` means "no
/// attribution" — callers treat the whole result as `nil` upstream.
///
/// `nonisolated` (overriding the module's default main-actor isolation) so the
/// parser and result can flow through the client's nonisolated `@Sendable`
/// closure without actor hops.
nonisolated struct FileBlame: Equatable, Sendable {
  var lines: [BlameLine]

  var isEmpty: Bool { lines.isEmpty }

  /// The attribution for the 1-based `line`, or `nil` when out of range.
  func line(_ line: Int) -> BlameLine? {
    lines.first { $0.lineNumber == line }
  }
}

/// One line's blame: which commit last touched it, by whom, when, and that
/// commit's summary. `commit` is the abbreviated (short) hash. An uncommitted /
/// working-tree line blames to the all-zero "not committed yet" pseudo-commit,
/// which git reports with author "Not Committed Yet"; `isUncommitted` flags it.
nonisolated struct BlameLine: Equatable, Sendable, Identifiable {
  /// 1-based line number in the current working-tree file.
  let lineNumber: Int
  /// Abbreviated commit hash (first 8 chars of the porcelain 40-char hash).
  let commit: String
  let author: String
  /// Commit author time. Built from the porcelain `author-time` epoch +
  /// `author-tz` offset; `nil` when the porcelain omitted them.
  let timestamp: Date?
  /// The commit's one-line summary.
  let summary: String

  var id: Int { lineNumber }

  /// The all-zero hash git uses for not-yet-committed local edits.
  var isUncommitted: Bool {
    commit.allSatisfy { $0 == "0" }
  }
}

extension FileBlame {
  /// Pure `git blame --line-porcelain` parser. Feed it raw porcelain output; get
  /// a `FileBlame`. Caseless enum (no top-level free funcs) so it is directly
  /// unit-testable without any git plumbing.
  ///
  /// Porcelain layout: each blamed line begins with a header line
  /// `<40-hex-sha> <origLine> <finalLine>[ <numLines>]`, followed by optional
  /// key/value lines (`author`, `author-time`, `author-tz`, `summary`, …), then
  /// a single content line prefixed with a TAB. In plain `--porcelain` the
  /// key/value block appears only the *first* time a commit is seen and is
  /// referenced by SHA thereafter; this parser caches per-SHA metadata so it
  /// handles both `--porcelain` and `--line-porcelain` output.
  nonisolated enum Parser {
    /// Metadata accumulated for a commit SHA across the porcelain stream.
    private struct CommitMeta {
      var author: String = ""
      var summary: String = ""
      var authorTime: Int?
    }

    static func parse(_ raw: String) -> FileBlame {
      var metaBySHA: [String: CommitMeta] = [:]
      var lines: [BlameLine] = []

      var currentSHA: String?
      var currentFinalLine: Int?

      for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        // A content line (the actual source text) begins with a TAB and closes
        // out the current line's record.
        if rawLine.hasPrefix("\t") {
          if let sha = currentSHA, let finalLine = currentFinalLine {
            let meta = metaBySHA[sha] ?? CommitMeta()
            lines.append(
              BlameLine(
                lineNumber: finalLine,
                commit: Self.shortSHA(sha),
                author: meta.author,
                timestamp: Self.date(epoch: meta.authorTime),
                summary: meta.summary
              )
            )
          }
          currentSHA = nil
          currentFinalLine = nil
          continue
        }

        // A header line: `<sha> <origLine> <finalLine>[ <numLines>]`. Detected by
        // a leading 40-char hex token.
        if let header = Self.parseHeader(rawLine) {
          currentSHA = header.sha
          currentFinalLine = header.finalLine
          if metaBySHA[header.sha] == nil {
            metaBySHA[header.sha] = CommitMeta()
          }
          continue
        }

        // Otherwise it's a key/value metadata line for the current commit.
        guard let sha = currentSHA else { continue }
        var meta = metaBySHA[sha] ?? CommitMeta()
        Self.apply(line: rawLine, to: &meta)
        metaBySHA[sha] = meta
      }

      return FileBlame(lines: lines)
    }

    private struct Header {
      let sha: String
      let finalLine: Int
    }

    /// Parse a porcelain header line into its SHA + final (current-file) line
    /// number. Returns `nil` for any line that isn't a header.
    private static func parseHeader(_ line: String) -> Header? {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard parts.count >= 3 else { return nil }
      let sha = parts[0]
      guard sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
      guard let finalLine = Int(parts[2]) else { return nil }
      return Header(sha: sha, finalLine: finalLine)
    }

    /// Apply a `key value` metadata line to the commit's accumulator.
    private static func apply(line: String, to meta: inout CommitMeta) {
      guard let spaceIndex = line.firstIndex(of: " ") else {
        // A bare key with no value (rare); ignore.
        return
      }
      let key = String(line[line.startIndex..<spaceIndex])
      let value = String(line[line.index(after: spaceIndex)...])
      switch key {
      case "author":
        meta.author = value
      case "summary":
        meta.summary = value
      case "author-time":
        meta.authorTime = Int(value)
      default:
        break
      }
    }

    /// First 8 chars of a 40-char SHA, matching git's default abbreviation feel.
    private static func shortSHA(_ sha: String) -> String {
      String(sha.prefix(8))
    }

    /// Build a `Date` from a Unix epoch. The git author-time is the absolute
    /// instant; the porcelain `author-tz` offset is cosmetic for display (the
    /// instant itself is timezone-independent), so we keep just the instant.
    private static func date(epoch: Int?) -> Date? {
      guard let epoch else { return nil }
      return Date(timeIntervalSince1970: TimeInterval(epoch))
    }
  }
}

extension GitBlameClient: DependencyKey {
  nonisolated static let liveValue = GitBlameClient(
    blame: { fileURL in
      await Self.computeBlame(for: fileURL)
    }
  )

  /// Resolve the file's repo root, then `git -C <root> blame --line-porcelain --
  /// <relPath>`, parse, and return `nil` for not-a-repo / untracked / git
  /// failure. Runs `git` via `Process` directly (capturing raw stdout) rather
  /// than via `ShellClient`, whose accumulator trims and re-joins lines — that
  /// would corrupt the porcelain stream's TAB-prefixed content lines.
  nonisolated private static func computeBlame(for fileURL: URL) async -> FileBlame? {
    let directory = fileURL.deletingLastPathComponent()
    guard let root = await repoRoot(forDirectory: directory) else { return nil }
    let relativePath = Self.relativePath(from: root, to: fileURL)
    guard
      let output = await runGit(
        arguments: [
          "-C", root.path(percentEncoded: false), "blame", "--line-porcelain", "--", relativePath,
        ],
        currentDirectory: root
      )
    else {
      return nil
    }
    let parsed = FileBlame.Parser.parse(output)
    return parsed.isEmpty ? nil : parsed
  }

  /// `git -C <dir> rev-parse --show-toplevel`. `nil` when `dir` isn't inside a
  /// git work tree (git exits non-zero / empty output).
  nonisolated private static func repoRoot(forDirectory directory: URL) async -> URL? {
    guard
      let output = await runGit(
        arguments: ["-C", directory.path(percentEncoded: false), "rev-parse", "--show-toplevel"],
        currentDirectory: directory
      )
    else {
      return nil
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed).standardizedFileURL
  }

  /// Run `git` via `Process`, returning raw stdout on exit 0, `nil` otherwise.
  /// Preserves stdout byte-for-byte (no line trimming) so the porcelain parser
  /// sees the exact stream. Locale pinned to C so `git`'s output isn't localized.
  nonisolated private static func runGit(arguments: [String], currentDirectory: URL) async -> String? {
    await withCheckedContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["git"] + arguments
      process.currentDirectoryURL = currentDirectory
      var environment = ProcessInfo.processInfo.environment
      environment["LANG"] = "C"
      environment["LC_ALL"] = "C"
      process.environment = environment
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.terminationHandler = { finished in
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        // Drain stderr so the pipe buffer can't fill and wedge a chatty git.
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard finished.terminationStatus == 0 else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
      }
      do {
        try process.run()
      } catch {
        gitBlameLogger.warning("Failed to launch git: \(error.localizedDescription)")
        continuation.resume(returning: nil)
      }
    }
  }

  /// Path of `target` relative to `base`, used as the `git blame -- <pathspec>`.
  /// Falls back to the file's last component when the file isn't under the root
  /// (shouldn't happen once the root is resolved from the file's own directory).
  nonisolated private static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard targetComponents.count > baseComponents.count,
      Array(targetComponents.prefix(baseComponents.count)) == baseComponents
    else {
      return target.lastPathComponent
    }
    return targetComponents.dropFirst(baseComponents.count).joined(separator: "/")
  }

  nonisolated static let testValue = GitBlameClient(
    blame: unimplemented("GitBlameClient.blame", placeholder: FileBlame?.none)
  )
}

extension DependencyValues {
  nonisolated var gitBlameClient: GitBlameClient {
    get { self[GitBlameClient.self] }
    set { self[GitBlameClient.self] = newValue }
  }
}
