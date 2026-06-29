import Foundation
import SupacodeSettingsShared

/// What a tab hosts. Terminal tabs own a `SplitTree<GhosttySurfaceView>`; editor
/// tabs own a `StoreOf<EditorFeature>` instead and never allocate a split tree.
/// Defaults to `.terminal` so every existing call site keeps compiling.
enum TerminalTabKind: Equatable, Sendable {
  case terminal
  case editor
}

struct TerminalTabItem: Identifiable, Equatable, Sendable {
  let id: TerminalTabID
  /// Live shell title; for display use `displayTitle`.
  var title: String
  /// User-supplied override; nil means follow the live shell title.
  var customTitle: String?
  var icon: String?
  var isDirty: Bool
  var isTitleLocked: Bool
  var tintColor: RepositoryColor?
  /// Sticky marker for tabs born from `runBlockingScript`; stays true after
  /// completion so guardrails outlive the script (these tabs die with the app).
  var isBlockingScript: Bool
  /// Flips true once `markBlockingScriptCompleted` runs. Distinguishes "running"
  /// from "frozen" so the view can show the lock indicator only post-completion.
  var isBlockingScriptCompleted: Bool
  /// Terminal vs editor. The tab bar derives icon / title / dirty / close /
  /// rename generically from this struct; the content view branches on `kind`
  /// to render either the split-tree pane or the in-app editor.
  var kind: TerminalTabKind

  var displayTitle: String { customTitle ?? title }

  init(
    id: TerminalTabID = TerminalTabID(),
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isDirty: Bool = false,
    isTitleLocked: Bool = false,
    tintColor: RepositoryColor? = nil,
    isBlockingScript: Bool = false,
    isBlockingScriptCompleted: Bool = false,
    kind: TerminalTabKind = .terminal
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.isDirty = isDirty
    self.isTitleLocked = isTitleLocked
    self.tintColor = tintColor
    self.isBlockingScript = isBlockingScript
    self.isBlockingScriptCompleted = isBlockingScriptCompleted
    self.kind = kind
  }
}
