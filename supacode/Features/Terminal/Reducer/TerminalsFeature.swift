import ComposableArchitecture
import Foundation

/// Owns the collection of per-tab `TerminalTabFeature` states. Mirrors the
/// sidebar's `RepositoriesFeature` ownership of `sidebarItems`. Views scope
/// through `store.scope(state: \.terminals, action: \.terminals)` so tab-bar
/// surface area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Bounded recent-removal memory. A late `tabProjectionChanged` emit landing
  /// after `tabRemoved` would otherwise re-insert a phantom tab; tracking the
  /// most recent removals lets the reducer drop those stragglers.
  static let recentlyRemovedTabLimit = 128

  /// Removed-tab record keyed by `(worktreeID, tabID)`. Same-session
  /// snapshot-restore reuses the persisted `tabSnapshot.id`, so scoping the
  /// dedup by worktree lets the FIFO drain when its owning worktree's state
  /// is torn down without shadowing a legitimate re-add.
  struct RecentlyRemovedTab: Equatable, Sendable {
    let worktreeID: Worktree.ID
    let tabID: TerminalTabID
  }

  @ObservableState
  struct State: Equatable {
    /// Per-tab feature instances keyed by `TerminalTabID`. Tab-bar leaves
    /// scope through `\.terminalTabs[id:]` for per-tab observation isolation
    /// during agent storms.
    var terminalTabs: IdentifiedArrayOf<TerminalTabFeature.State> = []
    /// Per-editor-tab feature instances keyed by `EditorFeature.State.id`, which
    /// is the tab's `TerminalTabID.rawValue`. The content view scopes through
    /// `\.editorTabs[id:]` and renders `EditorView` for the selected editor tab.
    var editorTabs: IdentifiedArrayOf<EditorFeature.State> = []
    /// FIFO of recently-removed tabs scoped by `(worktreeID, tabID)`. Insert
    /// order = removal order; oldest entry is dropped when the cap is hit.
    var recentlyRemovedTabIDs: [RecentlyRemovedTab] = []
    /// Maps an editor tab's `TerminalTabID` to its owning worktree, so the
    /// `worktreeStateTornDown` prune path can drop the right editor states (an
    /// editor tab emits no `WorktreeTabProjection`, so it isn't tracked in
    /// `terminalTabs`).
    var editorTabWorktreeIDs: [TerminalTabID: Worktree.ID] = [:]
  }

  enum Action {
    case terminalTabs(IdentifiedActionOf<TerminalTabFeature>)
    /// Per-editor-tab child actions (open / text / save / dirty delegate).
    case editorTabs(IdentifiedActionOf<EditorFeature>)
    /// Tab projection arrived from `WorktreeTerminalState`. Inserts a new
    /// per-tab state if missing, then forwards to the tab's reducer.
    case tabProjectionChanged(worktreeID: Worktree.ID, projection: WorktreeTabProjection)
    /// An editor tab was created in the worktree state. Spawns the matching
    /// `EditorFeature.State` (id == tab UUID) and kicks off the file load. `line`
    /// (1-based, optional) is a find-in-files jump target the editor scrolls to
    /// once loaded.
    case editorTabOpened(worktreeID: Worktree.ID, tabID: TerminalTabID, fileURL: URL?, line: Int? = nil)
    /// Tab destroyed in the worktree state. Drops the matching feature state
    /// (terminal or editor).
    case tabRemoved(worktreeID: Worktree.ID, tabID: TerminalTabID)
    /// Worktree's entire terminal state was torn down (prune path). Drops any
    /// orphan `terminalTabs` rows and removed-tab FIFO records for this
    /// worktree so a same-session re-attach starts clean.
    case worktreeStateTornDown(worktreeID: Worktree.ID)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .terminalTabs:
        return .none

      case .editorTabs:
        // Per-editor child actions (binding / load / save) are handled by the
        // scoped `EditorFeature` via `.forEach`. The dirty delegate is observed
        // upstream in `AppFeature` (it owns `terminalClient` to flip the tab's
        // dirty indicator), so nothing terminal-orchestration-level reacts here.
        return .none

      case .editorTabOpened(let worktreeID, let tabID, let fileURL, let line):
        if state.editorTabs[id: tabID.rawValue] == nil {
          // Drop a straggler arriving after the tab was already removed in this
          // worktree (mirrors `tabProjectionChanged`'s recently-removed guard).
          guard
            !state.recentlyRemovedTabIDs.contains(where: {
              $0.worktreeID == worktreeID && $0.tabID == tabID
            })
          else { return .none }
          state.editorTabs.append(
            EditorFeature.State(id: tabID.rawValue, fileURL: fileURL)
          )
          state.editorTabWorktreeIDs[tabID] = worktreeID
        }
        // Kick off the load through the scoped reducer's cancellable effect.
        // A nil fileURL leaves the editor empty (the worktree "open" entry point).
        guard let fileURL else { return .none }
        // With a find-in-files line, open-at-line so the editor scrolls to the
        // match once loaded (and re-scrolls when re-targeting an open file).
        if let line {
          return .send(.editorTabs(.element(id: tabID.rawValue, action: .openAtLine(fileURL, line: line))))
        }
        return .send(.editorTabs(.element(id: tabID.rawValue, action: .open(fileURL))))

      case .tabProjectionChanged(let worktreeID, let projection):
        let tabID = projection.tabID
        if state.terminalTabs[id: tabID] == nil {
          // Drop stale projections arriving after the tab was removed in this
          // worktree. Matching by (worktreeID, tabID) so a snapshot-restore
          // under a different worktree wouldn't be shadowed; the per-worktree
          // drain on teardown covers the same-worktree restore case.
          guard
            !state.recentlyRemovedTabIDs.contains(where: {
              $0.worktreeID == worktreeID && $0.tabID == tabID
            })
          else { return .none }
          state.terminalTabs.append(
            TerminalTabFeature.State(id: tabID, worktreeID: worktreeID)
          )
        }
        return .send(.terminalTabs(.element(id: tabID, action: .projectionChanged(projection))))

      case .tabRemoved(let worktreeID, let tabID):
        state.terminalTabs.remove(id: tabID)
        state.editorTabs.remove(id: tabID.rawValue)
        state.editorTabWorktreeIDs.removeValue(forKey: tabID)
        state.recentlyRemovedTabIDs.append(
          RecentlyRemovedTab(worktreeID: worktreeID, tabID: tabID)
        )
        if state.recentlyRemovedTabIDs.count > Self.recentlyRemovedTabLimit {
          state.recentlyRemovedTabIDs.removeFirst(
            state.recentlyRemovedTabIDs.count - Self.recentlyRemovedTabLimit
          )
        }
        return .none

      case .worktreeStateTornDown(let worktreeID):
        state.recentlyRemovedTabIDs.removeAll { $0.worktreeID == worktreeID }
        state.terminalTabs.removeAll { $0.worktreeID == worktreeID }
        let removedEditorTabIDs = state.editorTabWorktreeIDs
          .filter { $0.value == worktreeID }
          .map(\.key)
        for tabID in removedEditorTabIDs {
          state.editorTabs.remove(id: tabID.rawValue)
          state.editorTabWorktreeIDs.removeValue(forKey: tabID)
        }
        return .none
      }
    }
    .forEach(\.terminalTabs, action: \.terminalTabs) {
      TerminalTabFeature()
    }
    .forEach(\.editorTabs, action: \.editorTabs) {
      EditorFeature()
    }
  }
}
