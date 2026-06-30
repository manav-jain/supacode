import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let contentSearchFeatureLogger = SupaLogger("ContentSearch")

/// Find-in-files content search (VS Code ⇧⌘F style). Searches file CONTENTS
/// across either the currently selected worktree (default) or every local
/// worktree (Global scope). Scope is persisted via `@Shared(.appStorage)`.
/// Self-contained TCA feature, a sibling of `FileSearchFeature`. Gated behind
/// the `quickSearch` flag (the same flag as Quick Search).
@Reducer
struct ContentSearchFeature {
  /// Search breadth. `worktree` scopes to the selected worktree only; `global`
  /// spans every local worktree. Persisted by raw value through AppStorage.
  enum Scope: String, Equatable, Sendable {
    case worktree
    case global
  }

  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var query = ""
    /// Fixed-string vs regex + case sensitivity. Persisted toggles drive the
    /// engine on both the git-grep and Swift-fallback paths.
    var options = ContentSearchOptions()
    /// The worktree active when the finder opened — the only root searched in
    /// `.worktree` scope, and the default selection target.
    var selectedWorktreeID: Worktree.ID?
    /// Every local worktree root, used as the candidate set in `.global` scope.
    var roots: [ContentSearchRoot] = []
    var results: [ContentMatch] = []
    var selectedIndex: Int?

    /// Persisted scope, stored as the raw `Scope` value. Period-free key so
    /// swift-sharing observes it via efficient KVO, not notifications.
    @Shared(.appStorage("contentSearchScope")) var scopeRawValue: String = Scope.worktree.rawValue

    /// Decoded scope, defaulting to `.worktree` for any unknown persisted value.
    var scope: Scope {
      Scope(rawValue: scopeRawValue) ?? .worktree
    }

    /// Roots searched for the active scope: just the selected worktree's root in
    /// `.worktree` scope, every root in `.global`.
    var activeRoots: [ContentSearchRoot] {
      switch scope {
      case .worktree:
        guard let selectedWorktreeID else { return [] }
        return roots.filter { $0.worktreeID == selectedWorktreeID }
      case .global:
        return roots
      }
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case present(selectedWorktreeID: Worktree.ID, roots: [ContentSearchRoot])
    case setPresented(Bool)
    case setScope(Scope)
    case setCaseSensitive(Bool)
    case setRegex(Bool)
    case searchResponse([ContentMatch])
    case moveSelection(MoveDirection, itemsCount: Int)
    case activate(ContentMatch)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case openMatch(fileURL: URL, line: Int, worktreeID: Worktree.ID)
  }

  enum MoveDirection: Equatable {
    case up
    case down
  }

  private nonisolated enum CancelID {
    case search
  }

  /// Debounce window before issuing a search for the latest query. Content
  /// search is heavier than name search, so a slightly longer window than
  /// FileSearch's 150ms keeps it from grepping on every keystroke.
  private static let searchDebounce: Duration = .milliseconds(200)

  /// Cap on matches surfaced per query. The engine also caps internally; this
  /// bounds what the list ever renders.
  static let maxResults = 500

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.contentSearchClient) private var contentSearchClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.query):
        return searchEffect(state: &state)

      case .binding:
        return .none

      case .present(let selectedWorktreeID, let roots):
        state.isPresented = true
        state.selectedWorktreeID = selectedWorktreeID
        state.roots = roots
        state.query = ""
        state.results = []
        state.selectedIndex = nil
        return searchEffect(state: &state)

      case .setPresented(let isPresented):
        state.isPresented = isPresented
        if !isPresented {
          state.query = ""
          state.results = []
          state.selectedIndex = nil
          return .cancel(id: CancelID.search)
        }
        return .none

      case .setScope(let scope):
        state.$scopeRawValue.withLock { $0 = scope.rawValue }
        state.selectedIndex = nil
        return searchEffect(state: &state)

      case .setCaseSensitive(let caseSensitive):
        state.options.caseSensitive = caseSensitive
        state.selectedIndex = nil
        return searchEffect(state: &state)

      case .setRegex(let regex):
        state.options.regex = regex
        state.selectedIndex = nil
        return searchEffect(state: &state)

      case .searchResponse(let results):
        state.results = results
        if results.isEmpty {
          state.selectedIndex = nil
        } else if let selectedIndex = state.selectedIndex {
          state.selectedIndex = min(selectedIndex, results.count - 1)
        } else {
          state.selectedIndex = 0
        }
        return .none

      case .moveSelection(let direction, let itemsCount):
        guard itemsCount > 0 else {
          state.selectedIndex = nil
          return .none
        }
        let maxIndex = itemsCount - 1
        switch direction {
        case .up:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == 0 ? maxIndex : selectedIndex - 1
          } else {
            state.selectedIndex = maxIndex
          }
        case .down:
          if let selectedIndex = state.selectedIndex {
            state.selectedIndex = selectedIndex == maxIndex ? 0 : selectedIndex + 1
          } else {
            state.selectedIndex = 0
          }
        }
        return .none

      case .activate(let match):
        state.isPresented = false
        // Open in the editor for the match's OWN worktree, not the session's
        // selected one — a Global match can belong to any local worktree.
        return .merge(
          .cancel(id: CancelID.search),
          .send(
            .delegate(.openMatch(fileURL: match.fileURL, line: match.line, worktreeID: match.worktreeID))
          )
        )

      case .delegate:
        return .none
      }
    }
  }

  /// Debounced, flag-gated content search for the current query over the active
  /// scope's roots. Clears results synchronously (and cancels any in-flight
  /// search) when the feature flag is off, no root resolves, or the query is
  /// empty — content search has nothing to show for an empty query, so unlike
  /// the file-name finder it never populates a candidate list.
  private func searchEffect(state: inout State) -> Effect<Action> {
    let activeRoots = state.activeRoots
    let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard FeatureFlag.quickSearch.isEnabled, !activeRoots.isEmpty, !trimmed.isEmpty else {
      state.results = []
      state.selectedIndex = nil
      return .cancel(id: CancelID.search)
    }
    let query = state.query
    let options = state.options
    return .run { send in
      try await clock.sleep(for: Self.searchDebounce)
      let results = await contentSearchClient.search(query, activeRoots, options, Self.maxResults)
      await send(.searchResponse(results))
    }
    .cancellable(id: CancelID.search, cancelInFlight: true)
  }
}
