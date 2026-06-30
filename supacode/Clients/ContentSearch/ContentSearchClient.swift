import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let contentSearchLogger = SupaLogger("ContentSearch")

/// A single content-search root: one worktree's on-disk working directory plus
/// the "Repo / Worktree" label used to attribute matches in Global scope.
/// `isGitRepository` selects the engine — a git worktree prefers `git grep`
/// (fast, tracked files, respects gitignore); a folder falls back to a Swift
/// enumerator walk.
nonisolated struct ContentSearchRoot: Equatable, Sendable {
  let worktreeID: Worktree.ID
  let url: URL
  let displayName: String
  let isGitRepository: Bool
}

/// Tunable search options. `caseSensitive` defaults off (the snappy
/// quick-search feel); `regex` flips the query from a fixed string to a regular
/// expression in both engines.
nonisolated struct ContentSearchOptions: Equatable, Sendable {
  var caseSensitive: Bool
  var regex: Bool

  init(caseSensitive: Bool = false, regex: Bool = false) {
    self.caseSensitive = caseSensitive
    self.regex = regex
  }
}

/// A single content match surfaced by find-in-files. `relativePath` is relative
/// to its search root; `line` is 1-based; `matchRange` is the matched span
/// within `lineText` in UTF-16 code units (suitable as an `NSRange` for the
/// emphasized row). `id` is qualified by `worktreeID` + line so the same
/// relative path under two roots (Global scope) stays distinct.
nonisolated struct ContentMatch: Equatable, Sendable, Identifiable {
  let worktreeID: Worktree.ID
  let fileURL: URL
  let relativePath: String
  let line: Int
  let lineText: String
  let matchRange: NSRange
  let rootDisplayName: String

  var id: String { "\(worktreeID.rawValue):\(relativePath):\(line):\(matchRange.location)" }
}

/// Find-in-files content search. Mirrors `FileSearchClient`'s dependency shape:
/// a single `@Sendable` closure plus a `DependencyKey` conformance so reducers
/// can inject a stub in tests. Multi-root so a single call can span one worktree
/// (Worktree scope) or every local worktree (Global scope).
struct ContentSearchClient: Sendable {
  var search:
    @Sendable (
      _ query: String,
      _ roots: [ContentSearchRoot],
      _ options: ContentSearchOptions,
      _ maxResults: Int
    ) async -> [ContentMatch]
}

extension ContentSearchClient: DependencyKey {
  nonisolated static let liveValue = ContentSearchClient { query, roots, options, maxResults in
    await Task.detached(priority: .userInitiated) {
      await ContentSearchEngine.search(query: query, roots: roots, options: options, maxResults: maxResults)
    }
    .value
  }

  nonisolated static let testValue = ContentSearchClient { _, _, _, _ in [] }
}

extension DependencyValues {
  nonisolated var contentSearchClient: ContentSearchClient {
    get { self[ContentSearchClient.self] }
    set { self[ContentSearchClient.self] = newValue }
  }
}

/// Pure, testable content-search engine. Caseless enum (no top-level free
/// functions) so the matching logic has direct unit coverage independent of the
/// dependency wiring. `nonisolated` so the live client can run it off the main
/// actor.
nonisolated enum ContentSearchEngine {
  /// Directory names skipped anywhere in a path. Mirrors
  /// `FileSearchRanker.excludedDirectoryNames` so name- and content-search agree
  /// on what counts as noise.
  static let excludedDirectoryNames: Set<String> = FileSearchRanker.excludedDirectoryNames

  /// Hard cap on files scanned per root in the Swift fallback so a huge tree
  /// can't stall the search. Matches `FileSearchRanker.maxFilesScanned`.
  static let maxFilesScanned = FileSearchRanker.maxFilesScanned

  /// Per-file match cap in the Swift fallback so one giant file can't crowd out
  /// every other result.
  static let maxMatchesPerFile = 50

  /// Skip any file larger than this (bytes). A several-MB file is almost
  /// certainly generated / a blob, not something the user wants to grep.
  static let maxFileSizeBytes = 2 * 1024 * 1024

  /// Bytes sniffed from the head of a file to decide whether it's binary (a NUL
  /// byte in the first chunk is git's own heuristic).
  static let binarySniffByteCount = 8192

  /// Enumerate every root concurrently (off-main), tag each match with its
  /// owning root, merge in input-root order, and cap at `maxResults`. The
  /// single-root case (Worktree scope) is just a one-element `roots`.
  static func search(
    query: String,
    roots: [ContentSearchRoot],
    options: ContentSearchOptions,
    maxResults: Int
  ) async -> [ContentMatch] {
    guard maxResults > 0, !roots.isEmpty else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let merged: [[ContentMatch]] = await withTaskGroup(of: (Int, [ContentMatch]).self) { group in
      for (index, root) in roots.enumerated() {
        group.addTask {
          (index, await searchRoot(query: trimmed, root: root, options: options, maxResults: maxResults))
        }
      }
      var byIndex: [Int: [ContentMatch]] = [:]
      for await (index, matches) in group {
        byIndex[index] = matches
      }
      return roots.indices.map { byIndex[$0] ?? [] }
    }
    // Flatten in root order, then cap the merged set.
    return Array(merged.flatMap { $0 }.prefix(maxResults))
  }

  /// Search a single root: prefer `git grep` for a git worktree, fall back to
  /// the Swift enumerator otherwise (folder, or git grep unavailable / errored).
  static func searchRoot(
    query: String,
    root: ContentSearchRoot,
    options: ContentSearchOptions,
    maxResults: Int
  ) async -> [ContentMatch] {
    if root.isGitRepository {
      if let matches = await gitGrep(query: query, root: root, options: options, maxResults: maxResults) {
        return matches
      }
      contentSearchLogger.info(
        "git grep unavailable for \(root.url.lastPathComponent); falling back to Swift walk"
      )
    }
    return swiftWalk(query: query, root: root, options: options, maxResults: maxResults)
  }

  // MARK: - git grep engine.

  /// Run `git grep -n --no-color [-i] [-F] -e <query>` in the root's working
  /// directory and parse `path:line:text` lines into matches. Returns `nil`
  /// when git couldn't be invoked or exited with an error other than
  /// "no matches" (exit code 1 with empty output), so the caller can fall back
  /// to the Swift walk. An empty match set (no hits) returns `[]`, not `nil`.
  static func gitGrep(
    query: String,
    root: ContentSearchRoot,
    options: ContentSearchOptions,
    maxResults: Int
  ) async -> [ContentMatch]? {
    var arguments = ["git", "-C", root.url.path(percentEncoded: false), "grep", "-n", "--no-color"]
    if !options.caseSensitive {
      arguments.append("-I")  // skip binary files
      arguments.append("-i")
    } else {
      arguments.append("-I")
    }
    if !options.regex {
      arguments.append("-F")  // fixed-string match
    } else {
      arguments.append("-E")  // extended regex
    }
    arguments.append("-e")
    arguments.append(query)

    let env = URL(fileURLWithPath: "/usr/bin/env")
    let result: ProcessResult
    do {
      result = try await Self.runProcess(executableURL: env, arguments: arguments, currentDirectoryURL: root.url)
    } catch let error as GitGrepProcessError {
      // Exit code 1 with empty stdout means "no matches" — a successful empty
      // result, not a failure to invoke git.
      if error.exitCode == 1, error.stdout.isEmpty {
        return []
      }
      contentSearchLogger.info(
        "git grep failed (exit \(error.exitCode)) for \(root.url.lastPathComponent)"
      )
      return nil
    } catch {
      contentSearchLogger.warning("git grep could not be launched: \(error.localizedDescription)")
      return nil
    }
    if result.exitCode == 1, result.stdout.isEmpty {
      return []
    }
    return parseGitGrep(
      result.stdout,
      root: root,
      query: query,
      options: options,
      maxResults: maxResults
    )
  }

  /// Parse `git grep -n` output: each line is `relativePath:lineNumber:text`.
  /// The path may itself contain colons, so split on the first two only.
  static func parseGitGrep(
    _ output: String,
    root: ContentSearchRoot,
    query: String,
    options: ContentSearchOptions,
    maxResults: Int
  ) -> [ContentMatch] {
    var matches: [ContentMatch] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
      if matches.count >= maxResults { break }
      let line = String(rawLine)
      guard let parsed = splitGitGrepLine(line) else { continue }
      let lineText = parsed.text
      guard
        let matchRange = firstMatchRange(of: query, in: lineText, options: options)
      else {
        // git matched but our local range finder didn't (e.g. a regex git
        // accepted but NSRegularExpression rejected) — still surface the hit
        // with a zero-length range at the start so the row renders.
        matches.append(
          ContentMatch(
            worktreeID: root.worktreeID,
            fileURL: root.url.appending(path: parsed.path),
            relativePath: parsed.path,
            line: parsed.line,
            lineText: lineText,
            matchRange: NSRange(location: 0, length: 0),
            rootDisplayName: root.displayName
          )
        )
        continue
      }
      matches.append(
        ContentMatch(
          worktreeID: root.worktreeID,
          fileURL: root.url.appending(path: parsed.path),
          relativePath: parsed.path,
          line: parsed.line,
          lineText: lineText,
          matchRange: matchRange,
          rootDisplayName: root.displayName
        )
      )
    }
    return matches
  }

  /// One parsed `path:line:text` git-grep line.
  struct GitGrepLine: Equatable {
    let path: String
    let line: Int
    let text: String
  }

  /// Split one `path:line:text` git-grep line. Path may contain colons, so we
  /// find the colon that precedes the integer line number.
  static func splitGitGrepLine(_ line: String) -> GitGrepLine? {
    // Scan for ":<digits>:" — the first such colon-bounded integer is the line
    // number. We search left-to-right and accept the first separator whose
    // middle component is all digits.
    var searchStart = line.startIndex
    while let firstColon = line[searchStart...].firstIndex(of: ":") {
      let afterFirst = line.index(after: firstColon)
      guard let secondColon = line[afterFirst...].firstIndex(of: ":") else { return nil }
      let numberSlice = line[afterFirst..<secondColon]
      if !numberSlice.isEmpty, numberSlice.allSatisfy(\.isNumber), let lineNumber = Int(numberSlice) {
        let path = String(line[line.startIndex..<firstColon])
        let text = String(line[line.index(after: secondColon)...])
        guard !path.isEmpty else { return nil }
        return GitGrepLine(path: path, line: lineNumber, text: text)
      }
      searchStart = afterFirst
    }
    return nil
  }

  // MARK: - Swift fallback engine.

  /// Walk the tree under `root.url`, skip noise dirs / hidden entries / binary /
  /// oversized files, and scan each text file's lines for `query`. Capped per
  /// file and at `maxResults` overall.
  static func swiftWalk(
    query: String,
    root: ContentSearchRoot,
    options: ContentSearchOptions,
    maxResults: Int,
    fileManager: FileManager = .default
  ) -> [ContentMatch] {
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = fileManager.enumerator(
        at: root.url,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsHiddenFiles]
      )
    else {
      contentSearchLogger.warning("Unable to enumerate files at \(root.url.path(percentEncoded: false))")
      return []
    }
    var matches: [ContentMatch] = []
    var scanned = 0
    for case let url as URL in enumerator {
      if matches.count >= maxResults { break }
      scanned += 1
      if scanned > maxFilesScanned { break }
      let values = try? url.resourceValues(forKeys: Set(resourceKeys))
      if values?.isDirectory == true {
        if excludedDirectoryNames.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true else { continue }
      if let size = values?.fileSize, size > maxFileSizeBytes { continue }
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
      if isBinary(data) { continue }
      guard let contents = String(data: data, encoding: .utf8) else { continue }
      let fileMatches = scanLines(
        of: contents,
        query: query,
        options: options,
        root: root,
        fileURL: url
      )
      matches.append(contentsOf: fileMatches)
    }
    return matches
  }

  /// Scan a single file's contents line-by-line for `query`, producing at most
  /// `maxMatchesPerFile` matches. The owning `root` supplies the worktree id +
  /// display-name attribution and (with `fileURL`) the root-relative path. The
  /// caller bounds the overall result count, so this caps only per-file.
  static func scanLines(
    of contents: String,
    query: String,
    options: ContentSearchOptions,
    root: ContentSearchRoot,
    fileURL: URL
  ) -> [ContentMatch] {
    let rootPath = root.url.standardizedFileURL.path(percentEncoded: false)
    let relativePath = relativePath(of: fileURL, rootPath: rootPath)
    var matches: [ContentMatch] = []
    var lineNumber = 0
    // Split on newlines, keeping empty lines so line numbers stay 1:1 with the
    // file. `omittingEmptySubsequences: false` preserves blank lines.
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      lineNumber += 1
      if matches.count >= maxMatchesPerFile { break }
      // Drop a trailing CR for CRLF files so the displayed text is clean.
      var lineText = String(rawLine)
      if lineText.hasSuffix("\r") {
        lineText.removeLast()
      }
      guard let matchRange = firstMatchRange(of: query, in: lineText, options: options) else { continue }
      matches.append(
        ContentMatch(
          worktreeID: root.worktreeID,
          fileURL: fileURL,
          relativePath: relativePath,
          line: lineNumber,
          lineText: lineText,
          matchRange: matchRange,
          rootDisplayName: root.displayName
        )
      )
    }
    return matches
  }

  // MARK: - Match-range computation.

  /// First match span of `query` in `lineText`, as an `NSRange` in UTF-16 code
  /// units, or `nil` when the line doesn't match. Honors fixed-string vs regex
  /// and case sensitivity from `options`.
  static func firstMatchRange(
    of query: String,
    in lineText: String,
    options: ContentSearchOptions
  ) -> NSRange? {
    if options.regex {
      var regexOptions: NSRegularExpression.Options = []
      if !options.caseSensitive {
        regexOptions.insert(.caseInsensitive)
      }
      guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions) else {
        return nil
      }
      let full = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
      guard let match = regex.firstMatch(in: lineText, options: [], range: full) else { return nil }
      return match.range
    }
    let compareOptions: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
    guard let range = lineText.range(of: query, options: compareOptions) else { return nil }
    return NSRange(range, in: lineText)
  }

  // MARK: - Helpers.

  /// True when the first chunk of `data` contains a NUL byte — git's own
  /// heuristic for "this is binary, skip it".
  static func isBinary(_ data: Data) -> Bool {
    let prefix = data.prefix(binarySniffByteCount)
    return prefix.contains(0x00)
  }

  private static func relativePath(of url: URL, rootPath: String) -> String {
    let standardized = url.standardizedFileURL.path(percentEncoded: false)
    guard standardized.hasPrefix(rootPath) else {
      return url.lastPathComponent
    }
    var relative = String(standardized.dropFirst(rootPath.count))
    if relative.hasPrefix("/") {
      relative.removeFirst()
    }
    return relative.isEmpty ? url.lastPathComponent : relative
  }

  // MARK: - Process plumbing.

  /// A finished process's captured output + exit code.
  struct ProcessResult {
    let stdout: String
    let exitCode: Int32
  }

  /// Error carrying git grep's exit code + captured stdout so the caller can
  /// distinguish "no matches" (exit 1, empty) from a real failure.
  struct GitGrepProcessError: Error {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  /// Run a process to completion and return its stdout + exit code. Throws
  /// `GitGrepProcessError` on a non-zero exit (carrying the captured output) or
  /// rethrows a launch failure. Mirrors `GitClient`'s direct-`Process` usage.
  static func runProcess(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = executableURL
      process.arguments = arguments
      process.currentDirectoryURL = currentDirectoryURL
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      process.terminationHandler = { finished in
        let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = finished.terminationStatus
        if code == 0 {
          continuation.resume(returning: ProcessResult(stdout: stdout, exitCode: code))
        } else {
          continuation.resume(
            throwing: GitGrepProcessError(exitCode: code, stdout: stdout, stderr: stderr)
          )
        }
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
