import Foundation

/// In-development capabilities are gated behind two feature flags so they stay
/// hidden until a user opts in from Settings → Feature Flags. Both default to
/// `false`.
///
/// Backed by `UserDefaults` (the same store `@Shared(.appStorage)` writes to), so
/// pure domain code such as `OpenWorktreeAction` can read a flag synchronously
/// without reaching for a TCA store.
public enum FeatureFlag: String, CaseIterable, Sendable {
  /// The built-in Supacode editor and everything it brings: the `supacode`
  /// editor target, editor tabs, syntax highlighting, auto-save, file-change
  /// reload, diff view, and git gutter / blame.
  case editorView
  /// Fast file search (worktree-scoped and global) plus find-in-files content
  /// search, surfaced through the command palette.
  case quickSearch

  /// `UserDefaults` / `appStorage` key. Namespaced so it never collides with a
  /// persisted setting key.
  public var storageKey: String { "featureFlag.\(rawValue)" }

  public var title: String {
    switch self {
    case .editorView: "Editor view"
    case .quickSearch: "Quick search"
    }
  }

  public var subtitle: String {
    switch self {
    case .editorView: "The built-in Supacode editor: tabs, syntax highlighting, diff, and git blame."
    case .quickSearch: "Search files and their contents across the worktree or all repositories."
    }
  }

  /// Whether the user has enabled this flag. Reads the same `UserDefaults` store
  /// that `@Shared(.appStorage(storageKey))` writes to, so the answer is always
  /// in sync with the Settings toggle.
  public var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: storageKey)
  }
}
