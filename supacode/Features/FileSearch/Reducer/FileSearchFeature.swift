import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let fileSearchFeatureLogger = SupaLogger("FileSearch")

/// Quick-open file finder (VS Code ⌘P style), scoped to the currently selected
/// worktree. Self-contained TCA feature — deliberately NOT folded into the
/// view-driven `CommandPaletteFeature`. Gated behind the `quickSearch` flag.
@Reducer
struct FileSearchFeature {
  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var query = ""
    var worktreeID: Worktree.ID?
    var rootURL: URL?
    var results: [FileSearchResult] = []
    var selectedIndex: Int?
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case present(worktreeID: Worktree.ID, rootURL: URL)
    case setPresented(Bool)
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

      case .present(let worktreeID, let rootURL):
        state.isPresented = true
        state.worktreeID = worktreeID
        state.rootURL = rootURL
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
        guard let worktreeID = state.worktreeID else {
          fileSearchFeatureLogger.warning("Activate ignored: no worktree associated with the file search session.")
          return .cancel(id: CancelID.search)
        }
        return .merge(
          .cancel(id: CancelID.search),
          .send(.delegate(.openFile(url: result.absoluteURL, worktreeID: worktreeID)))
        )

      case .delegate:
        return .none
      }
    }
  }

  /// Debounced, flag-gated search for the current query. No-ops (and clears any
  /// in-flight search) when the feature flag is off or no root is set, so the
  /// results never populate while the feature is disabled.
  private func searchEffect(state: State) -> Effect<Action> {
    guard FeatureFlag.quickSearch.isEnabled, let rootURL = state.rootURL else {
      return .cancel(id: CancelID.search)
    }
    let query = state.query
    return .run { send in
      try await clock.sleep(for: Self.searchDebounce)
      let results = await fileSearchClient.search(query, rootURL, Self.maxResults)
      await send(.searchResponse(results))
    }
    .cancellable(id: CancelID.search, cancelInFlight: true)
  }
}
