import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let fileSearchFeatureLogger = SupaLogger("FileSearch")

/// Quick-open file finder (VS Code ⌘P style). Searches either the currently
/// selected worktree (default) or every local worktree (Global scope). Scope is
/// persisted via `@Shared(.appStorage)`. Self-contained TCA feature —
/// deliberately NOT folded into the view-driven `CommandPaletteFeature`. Gated
/// behind the `quickSearch` flag.
@Reducer
struct FileSearchFeature {
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
    /// The worktree active when the finder opened — the only root searched in
    /// `.worktree` scope, and the default selection target.
    var selectedWorktreeID: Worktree.ID?
    /// Every local worktree root, used as the candidate set in `.global` scope.
    var roots: [FileSearchRoot] = []
    var results: [FileSearchResult] = []
    var selectedIndex: Int?

    /// Persisted scope, stored as the raw `Scope` value (AppStorage-friendly).
    /// Period-free key (matches the codebase convention for `@Shared(.appStorage)`
    /// keys) so swift-sharing observes it via efficient KVO, not notifications.
    @Shared(.appStorage("fileSearchScope")) var scopeRawValue: String = Scope.worktree.rawValue

    /// Decoded scope, defaulting to `.worktree` for any unknown persisted value.
    var scope: Scope {
      Scope(rawValue: scopeRawValue) ?? .worktree
    }

    /// Roots searched for the active scope: just the selected worktree's root in
    /// `.worktree` scope, every root in `.global`.
    var activeRoots: [FileSearchRoot] {
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
    case present(selectedWorktreeID: Worktree.ID, roots: [FileSearchRoot])
    case setPresented(Bool)
    case setScope(Scope)
    case searchResponse([FileSearchResult])
    case moveSelection(MoveDirection, itemsCount: Int)
    case activate(FileSearchResult)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case openFile(url: URL, worktreeID: Worktree.ID)
  }

  enum MoveDirection: Equatable {
    case up
    case down
  }

  private nonisolated enum CancelID {
    case search
  }

  /// Debounce window before issuing a search for the latest query. Matches the
  /// snappy feel of a quick-open palette without a request per keystroke.
  private static let searchDebounce: Duration = .milliseconds(150)

  /// Cap on results surfaced per query. The ranker also caps internally; this
  /// bounds what the list ever renders.
  private static let maxResults = 200

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.fileSearchClient) private var fileSearchClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.query):
        return searchEffect(state: state)

      case .binding:
        return .none

      case .present(let selectedWorktreeID, let roots):
        state.isPresented = true
        state.selectedWorktreeID = selectedWorktreeID
        state.roots = roots
        state.query = ""
        state.results = []
        state.selectedIndex = nil
        return searchEffect(state: state)

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
        // Persist the chosen scope, then re-run the search over the new scope's
        // root subset. Selection resets so the list lands on the first row.
        state.$scopeRawValue.withLock { $0 = scope.rawValue }
        state.selectedIndex = nil
        return searchEffect(state: state)

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

      case .activate(let result):
        state.isPresented = false
        // Open in the editor for the result's OWN worktree, not the session's
        // selected one — a Global result can belong to any local worktree.
        return .merge(
          .cancel(id: CancelID.search),
          .send(.delegate(.openFile(url: result.absoluteURL, worktreeID: result.worktreeID)))
        )

      case .delegate:
        return .none
      }
    }
  }

  /// Debounced, flag-gated search for the current query over the active scope's
  /// roots. No-ops (and clears any in-flight search) when the feature flag is
  /// off or no root resolves for the active scope, so the results never populate
  /// while the feature is disabled.
  private func searchEffect(state: State) -> Effect<Action> {
    let activeRoots = state.activeRoots
    guard FeatureFlag.quickSearch.isEnabled, !activeRoots.isEmpty else {
      return .cancel(id: CancelID.search)
    }
    let query = state.query
    return .run { send in
      try await clock.sleep(for: Self.searchDebounce)
      let results = await fileSearchClient.search(query, activeRoots, Self.maxResults)
      await send(.searchResponse(results))
    }
    .cancellable(id: CancelID.search, cancelInFlight: true)
  }
}
