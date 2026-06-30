import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let fileDiffLogger = SupaLogger("FileDiffClient")

/// Computes the working-tree-vs-HEAD diff of a single file for the in-app
/// editor's diff view (Phase 9). Mirrors the `EditorFileClient` dependency
/// shape: a struct of `@Sendable` closures plus a `DependencyKey` conformance so
/// reducers inject a stub in tests. Gated upstream behind `FeatureFlag.editorView`
/// — nothing here touches the flag because the only caller (the editor feature)
/// is itself reachable only when the flag is on.
struct FileDiffClient: Sendable {
  /// Diff `fileURL`'s on-disk contents against HEAD. Returns `nil` when the file
  /// isn't in a git repo, is untracked, or has no changes — i.e. there is nothing
  /// to render. Never throws: a non-repo / git failure is just "no diff".
  var diff: @Sendable (_ fileURL: URL) async -> FileDiff?
}

/// A parsed unified diff for a single file: an ordered list of hunks. Empty
/// `hunks` means "no changes" — callers treat the whole result as `nil` upstream,
/// but the type stays renderable on its own for the empty state.
///
/// `nonisolated` (overriding the module's default main-actor isolation) so the
/// parser and the diff result can flow through the client's nonisolated
/// `@Sendable` closure without actor hops.
nonisolated struct FileDiff: Equatable, Sendable {
  var hunks: [DiffHunk]

  var isEmpty: Bool { hunks.isEmpty }
}

/// One `@@ -oldStart,oldCount +newStart,newCount @@` hunk and its body lines.
nonisolated struct DiffHunk: Equatable, Sendable, Identifiable {
  /// Stable within a `FileDiff`: hunks are appended in parse order, so the index
  /// is a sufficient identity for `ForEach` rendering.
  let id: Int
  /// The raw `@@ … @@` header line (trailing section context preserved), shown
  /// in secondary style above the hunk body.
  let header: String
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  var lines: [DiffLine]
}

/// One body line of a hunk: a context line (unchanged), an added line, or a
/// removed line. Old/new line numbers are present only where they apply (an
/// added line has no old number; a removed line has no new number).
nonisolated struct DiffLine: Equatable, Sendable, Identifiable {
  nonisolated enum Kind: Equatable, Sendable {
    case context
    case added
    case removed
  }

  /// Stable within a hunk: lines are appended in parse order.
  let id: Int
  let kind: Kind
  /// The line text WITHOUT the leading `+` / `-` / ` ` diff marker.
  let text: String
  let oldLineNumber: Int?
  let newLineNumber: Int?
}

extension FileDiff {
  /// Pure unified-diff parser. Feed it raw `git diff --no-color` output for a
  /// single file; get a `FileDiff`. Caseless enum (no top-level free funcs) so it
  /// is directly unit-testable without any git plumbing.
  ///
  /// Handles the file header (`diff --git`, `index`, `---`, `+++`, mode / rename
  /// metadata) by skipping everything before the first `@@` hunk, then walks each
  /// hunk tracking old/new line numbers. A `\ No newline at end of file` marker is
  /// dropped. Empty or hunk-less output → an empty `FileDiff`.
  nonisolated enum Parser {
    /// The four numbers parsed out of a `@@ -a,b +c,d @@` hunk header.
    private struct HunkRange {
      let oldStart: Int
      let oldCount: Int
      let newStart: Int
      let newCount: Int
    }

    static func parse(_ raw: String) -> FileDiff {
      var hunks: [DiffHunk] = []
      var current: DiffHunk?
      var oldLine = 0
      var newLine = 0
      var lineIndex = 0

      func flush() {
        if let current {
          hunks.append(current)
        }
        current = nil
      }

      // `split(omittingEmptySubsequences: false)` keeps blank context lines (a
      // context line whose only content is the leading space → "" after we drop
      // the marker). `git diff` always emits at least the marker, so a truly
      // empty body line would be a trailing newline artifact, handled below.
      for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if let range = parseHunkHeader(rawLine) {
          flush()
          oldLine = range.oldStart
          newLine = range.newStart
          lineIndex = 0
          current = DiffHunk(
            id: hunks.count,
            header: rawLine,
            oldStart: range.oldStart,
            oldCount: range.oldCount,
            newStart: range.newStart,
            newCount: range.newCount,
            lines: []
          )
          continue
        }

        // Everything before the first hunk (file header, index, ---/+++) is
        // metadata we don't render.
        guard current != nil else { continue }

        // The "no newline at end of file" sentinel applies to the previous line,
        // not a body line of its own.
        if rawLine.hasPrefix(#"\"#) { continue }

        guard let marker = rawLine.first else {
          // A truly empty string here is the trailing element from the final
          // newline split; ignore it rather than emit a phantom context line.
          continue
        }
        let text = String(rawLine.dropFirst())
        switch marker {
        case "+":
          current?.lines.append(
            DiffLine(id: lineIndex, kind: .added, text: text, oldLineNumber: nil, newLineNumber: newLine)
          )
          newLine += 1
        case "-":
          current?.lines.append(
            DiffLine(id: lineIndex, kind: .removed, text: text, oldLineNumber: oldLine, newLineNumber: nil)
          )
          oldLine += 1
        case " ":
          current?.lines.append(
            DiffLine(id: lineIndex, kind: .context, text: text, oldLineNumber: oldLine, newLineNumber: newLine)
          )
          oldLine += 1
          newLine += 1
        default:
          // A line that isn't a hunk marker once we're inside a hunk means the
          // hunk body ended (e.g. a second file's `diff --git`). Close it out.
          flush()
          continue
        }
        lineIndex += 1
      }

      flush()
      return FileDiff(hunks: hunks)
    }

    /// Parse a `@@ -<oldStart>[,<oldCount>] +<newStart>[,<newCount>] @@[ section]`
    /// header into its four numbers (`count` defaults to 1 when omitted, per the
    /// unified-diff spec). Returns `nil` for any line that isn't a hunk header.
    /// Hand-rolled rather than a typed-capture `Regex` so it stays `Sendable`-free
    /// (no static stored regex) and avoids a five-member capture tuple.
    private static func parseHunkHeader(_ line: String) -> HunkRange? {
      guard line.hasPrefix("@@ -") else { return nil }
      // Body is the text between the leading `@@ ` and the closing ` @@`.
      let afterPrefix = line.dropFirst(3)  // drop "@@ "
      guard let closing = afterPrefix.range(of: " @@") else { return nil }
      let body = afterPrefix[afterPrefix.startIndex..<closing.lowerBound]
      // body == "-a,b +c,d" (each `,b` optional). Split on the single space.
      let parts = body.split(separator: " ", omittingEmptySubsequences: true)
      guard parts.count == 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
      guard
        let old = parseRange(parts[0].dropFirst()),
        let new = parseRange(parts[1].dropFirst())
      else {
        return nil
      }
      return HunkRange(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    /// Parse a `start[,count]` range fragment. `count` defaults to 1.
    private static func parseRange(_ fragment: Substring) -> (start: Int, count: Int)? {
      let numbers = fragment.split(separator: ",", omittingEmptySubsequences: true)
      guard let first = numbers.first, let start = Int(first) else { return nil }
      let count = numbers.count > 1 ? (Int(numbers[1]) ?? 1) : 1
      return (start, count)
    }
  }
}

extension FileDiffClient: DependencyKey {
  nonisolated static let liveValue = FileDiffClient(
    diff: { fileURL in
      await Self.computeDiff(for: fileURL)
    }
  )

  /// Resolve the file's repo root, then `git diff --no-color HEAD -- <relPath>`,
  /// parse, and return `nil` for not-a-repo / untracked / no-change. Runs `git`
  /// via `Process` directly (capturing raw stdout) rather than via `ShellClient`,
  /// whose accumulator trims and re-joins lines — that would corrupt a unified
  /// diff's blank context lines and trailing-space markers.
  nonisolated private static func computeDiff(for fileURL: URL) async -> FileDiff? {
    let directory = fileURL.deletingLastPathComponent()
    guard let root = await repoRoot(forDirectory: directory) else { return nil }
    let relativePath = Self.relativePath(from: root, to: fileURL)
    guard
      let output = await runGit(
        arguments: ["-C", root.path(percentEncoded: false), "diff", "--no-color", "HEAD", "--", relativePath],
        currentDirectory: root
      )
    else {
      return nil
    }
    let parsed = FileDiff.Parser.parse(output)
    // Untracked / no-change both surface as empty output → empty hunks → nil.
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
  /// Preserves stdout byte-for-byte (no line trimming) so the diff parser sees
  /// the exact unified-diff text. Locale pinned to C so `git`'s output isn't
  /// localized.
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
        fileDiffLogger.warning("Failed to launch git: \(error.localizedDescription)")
        continuation.resume(returning: nil)
      }
    }
  }

  /// Path of `target` relative to `base`, used as the `git diff -- <pathspec>`.
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

  nonisolated static let testValue = FileDiffClient(
    diff: unimplemented("FileDiffClient.diff", placeholder: FileDiff?.none)
  )
}

extension DependencyValues {
  nonisolated var fileDiffClient: FileDiffClient {
    get { self[FileDiffClient.self] }
    set { self[FileDiffClient.self] = newValue }
  }
}
