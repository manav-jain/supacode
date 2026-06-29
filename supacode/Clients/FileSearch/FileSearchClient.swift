import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let fileSearchLogger = SupaLogger("FileSearch")

/// A single file match surfaced by the quick-open finder. `relativePath` is the
/// path relative to the search root and doubles as the stable identity (used for
/// display and de-duplication in the results list).
nonisolated struct FileSearchResult: Equatable, Sendable, Identifiable {
  let absoluteURL: URL
  let relativePath: String
  var id: String { relativePath }
}

/// Worktree-scoped quick-open file finder. Mirrors the `WorkspaceClient`
/// dependency shape: a single `@Sendable` closure plus a `DependencyKey`
/// conformance so reducers can inject a stub in tests.
struct FileSearchClient: Sendable {
  var search: @Sendable (_ query: String, _ root: URL, _ maxResults: Int) async -> [FileSearchResult]
}

extension FileSearchClient: DependencyKey {
  nonisolated static let liveValue = FileSearchClient { query, root, maxResults in
    await Task.detached(priority: .userInitiated) {
      FileSearchRanker.search(query: query, root: root, maxResults: maxResults)
    }
    .value
  }

  nonisolated static let testValue = FileSearchClient { _, _, _ in [] }
}

extension DependencyValues {
  nonisolated var fileSearchClient: FileSearchClient {
    get { self[FileSearchClient.self] }
    set { self[FileSearchClient.self] = newValue }
  }
}

/// Pure, testable enumeration + ranking for the quick-open finder. Caseless enum
/// (no top-level free functions) so the matching / scoring logic has direct unit
/// coverage independent of the dependency wiring. `nonisolated` so the live
/// client can run it off the main actor.
nonisolated enum FileSearchRanker {
  /// Directory names skipped anywhere in a path. Mirrors the spirit of
  /// `OpenWorktreeAction.xcodeSearchExcludedDirectories` — noise that should
  /// never surface as an openable file.
  static let excludedDirectoryNames: Set<String> = [
    ".git",
    "node_modules",
    ".build",
    "DerivedData",
    "Pods",
    "Carthage",
    ".swiftpm",
    "dist",
    "build",
    ".next",
    ".venv",
    "__pycache__",
    ".gradle",
    ".yarn",
    "target",
  ]

  /// Hard cap on files scanned so a huge tree can't stall the finder.
  static let maxFilesScanned = 20_000

  /// Enumerate regular files under `root`, then rank them against `query`.
  /// When `query` is empty the first `maxResults` files are returned in stable
  /// enumeration order. Runs synchronously; the live client hops it off the main
  /// thread.
  static func search(query: String, root: URL, maxResults: Int) -> [FileSearchResult] {
    guard maxResults > 0 else { return [] }
    let candidates = enumerateFiles(root: root)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return Array(candidates.prefix(maxResults))
    }
    let lowercasedQuery = trimmed.lowercased()
    let scored: [(result: FileSearchResult, score: Int)] = candidates.compactMap { candidate in
      guard let score = self.score(query: lowercasedQuery, relativePath: candidate.relativePath) else {
        return nil
      }
      return (candidate, score)
    }
    // Higher score first; ties broken by shorter path then case-insensitive path
    // for a stable, predictable order.
    let ranked = scored.sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      if lhs.result.relativePath.count != rhs.result.relativePath.count {
        return lhs.result.relativePath.count < rhs.result.relativePath.count
      }
      return lhs.result.relativePath.localizedCaseInsensitiveCompare(rhs.result.relativePath) == .orderedAscending
    }
    return ranked.prefix(maxResults).map(\.result)
  }

  /// Walk the tree, skipping hidden entries and any excluded directory, and
  /// return regular files (capped at `maxFilesScanned`) as `FileSearchResult`s
  /// with their root-relative paths.
  static func enumerateFiles(root: URL, fileManager: FileManager = .default) -> [FileSearchResult] {
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsHiddenFiles]
      )
    else {
      fileSearchLogger.warning("Unable to enumerate files at \(root.path(percentEncoded: false))")
      return []
    }
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    var results: [FileSearchResult] = []
    var scanned = 0
    for case let url as URL in enumerator {
      scanned += 1
      if scanned > maxFilesScanned {
        break
      }
      let values = try? url.resourceValues(forKeys: Set(resourceKeys))
      if values?.isDirectory == true {
        if excludedDirectoryNames.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true else { continue }
      let relativePath = Self.relativePath(of: url, rootPath: rootPath)
      results.append(FileSearchResult(absoluteURL: url, relativePath: relativePath))
    }
    return results
  }

  /// Score a candidate against an already-lowercased query, or `nil` when there
  /// is no match. Ranking: exact basename prefix > basename substring > path
  /// subsequence (fuzzy). Higher is better.
  static func score(query: String, relativePath: String) -> Int? {
    let basename = (relativePath as NSString).lastPathComponent.lowercased()
    let lowercasedPath = relativePath.lowercased()
    if basename.hasPrefix(query) {
      return 300
    }
    if basename.contains(query) {
      return 200
    }
    if isSubsequence(query, of: basename) {
      return 150
    }
    if isSubsequence(query, of: lowercasedPath) {
      return 100
    }
    return nil
  }

  /// Whether every character of `needle` appears in `haystack` in order
  /// (classic fuzzy subsequence match). Both are expected to be lowercased.
  static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    guard !needle.isEmpty else { return true }
    var needleIndex = needle.startIndex
    for character in haystack where character == needle[needleIndex] {
      needleIndex = needle.index(after: needleIndex)
      if needleIndex == needle.endIndex {
        return true
      }
    }
    return false
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
}
