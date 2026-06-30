import Foundation
import SupacodeSettingsShared
import SwiftTreeSitter
import TreeSitterSwift

nonisolated private let editorLanguageLogger = SupaLogger("EditorLanguage")

/// The set of source languages the editor can syntax-highlight and extract
/// symbols from. v1 ships Swift; the design is a registry so adding a grammar
/// later is a new `case` + one row in `forFileExtension` plus its
/// `LanguageConfiguration`.
///
/// Each case knows how to build a SwiftTreeSitter `LanguageConfiguration`
/// (the tree-sitter `Language` plus its bundled `highlights` / `locals` /
/// `injections` queries) and to load its `tags` query for symbol navigation.
/// Loading is cached per case so repeated reparses don't recompile the queries
/// (query compilation is expensive — see `SwiftTreeSitter.Query`).
enum EditorLanguage: String, CaseIterable, Sendable {
  case swift

  /// Detect the language from a file URL's path extension. Unknown extensions
  /// return `nil`, which the caller renders as plain text (no crash).
  static func forFileURL(_ url: URL?) -> EditorLanguage? {
    guard let url else { return nil }
    return forFileExtension(url.pathExtension)
  }

  /// Detect the language from a bare path extension (case-insensitive).
  static func forFileExtension(_ ext: String) -> EditorLanguage? {
    switch ext.lowercased() {
    case "swift":
      return .swift
    default:
      return nil
    }
  }

  /// The tree-sitter `Language` (grammar) for this case.
  var tsLanguage: Language {
    switch self {
    case .swift:
      return Language(tree_sitter_swift())
    }
  }

  /// The bundle base name SwiftTreeSitter uses to auto-discover the grammar's
  /// query `.scm` files. SPM emits a resource bundle named
  /// `TreeSitter<Name>_TreeSitter<Name>.bundle` for each grammar package.
  var queryBundleName: String {
    switch self {
    case .swift:
      return "TreeSitterSwift_TreeSitterSwift"
    }
  }

  /// The display name passed to `LanguageConfiguration`.
  var grammarName: String {
    switch self {
    case .swift:
      return "Swift"
    }
  }

  // MARK: - Loading

  /// A loaded grammar: its parser language, the `highlights` query (for syntax
  /// coloring), and the `tags` query (for symbol navigation). Either query may
  /// be absent if the grammar bundle doesn't ship it.
  struct Loaded: Sendable {
    let language: Language
    let highlights: Query?
    let tags: Query?
  }

  /// Process-wide cache of loaded grammars. Query compilation is expensive, so
  /// we do it once per language. Guarded by `cacheLock` for thread safety since
  /// callers may live off the main actor.
  nonisolated(unsafe) private static var cache: [EditorLanguage: Loaded] = [:]
  private static let cacheLock = NSLock()

  /// Load (or return the cached) grammar + queries for this case. Returns `nil`
  /// only if the grammar bundle can't be located at all; a missing individual
  /// query degrades gracefully (that feature is simply unavailable).
  func load() -> Loaded? {
    Self.cacheLock.lock()
    defer { Self.cacheLock.unlock() }

    if let cached = Self.cache[self] {
      return cached
    }

    let language = tsLanguage
    guard let queriesURL = Self.queriesDirectoryURL(bundleName: queryBundleName) else {
      editorLanguageLogger.warning("Could not locate query bundle \(queryBundleName) for \(grammarName)")
      let loaded = Loaded(language: language, highlights: nil, tags: nil)
      Self.cache[self] = loaded
      return loaded
    }

    let highlights = Self.loadQuery(named: "highlights", language: language, in: queriesURL)
    let tags = Self.loadQuery(named: "tags", language: language, in: queriesURL)

    let loaded = Loaded(language: language, highlights: highlights, tags: tags)
    Self.cache[self] = loaded
    return loaded
  }

  // MARK: - Bundle resolution

  /// Locate the grammar's `queries` directory inside its SPM resource bundle.
  ///
  /// SwiftTreeSitter's own `LanguageConfiguration` relies on `Bundle.main`,
  /// which is correct for the running app but unreliable under the XCTest /
  /// Swift-Testing runner (the app bundle isn't `main`). We search every
  /// loaded bundle plus `Bundle.main`, so the same code path works in the app
  /// and in tests.
  static func queriesDirectoryURL(bundleName: String) -> URL? {
    let candidateContainers: [URL] = {
      var urls: [URL] = []
      if let mainResources = Bundle.main.resourceURL {
        urls.append(mainResources)
      }
      urls.append(Bundle.main.bundleURL)
      for bundle in Bundle.allBundles + Bundle.allFrameworks {
        if let resourceURL = bundle.resourceURL {
          urls.append(resourceURL)
        }
        urls.append(bundle.bundleURL)
        urls.append(bundle.bundleURL.deletingLastPathComponent())
      }
      return urls
    }()

    for container in candidateContainers {
      let bundleURL = container.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
      let queriesURL = bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true)
      if FileManager.default.fileExists(atPath: queriesURL.path) {
        return queriesURL
      }
      // iOS-style flat layout fallback.
      let flatQueriesURL = bundleURL.appendingPathComponent("queries", isDirectory: true)
      if FileManager.default.fileExists(atPath: flatQueriesURL.path) {
        return flatQueriesURL
      }
    }

    return nil
  }

  /// Compile a single `<name>.scm` query from a queries directory. Returns
  /// `nil` (and logs) if the file is missing or fails to compile, so one bad
  /// query never blocks the rest of highlighting.
  private static func loadQuery(named name: String, language: Language, in queriesURL: URL) -> Query? {
    let url = queriesURL.appendingPathComponent("\(name).scm")
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return nil
    }
    do {
      return try Query(language: language, url: url)
    } catch {
      editorLanguageLogger.warning("Failed to compile \(name).scm: \(error)")
      return nil
    }
  }
}
