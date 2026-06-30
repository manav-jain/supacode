import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

// Serialized because several cases mutate the process-global `quickSearch`
// `UserDefaults` flag and the persisted `fileSearchScope` AppStorage value;
// parallel execution would race on both.
@MainActor
@Suite(.serialized)
struct FileSearchFeatureTests {
  // MARK: - Presentation.

  @Test func presentSetsStateAndTriggersInitialSearch() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let stub = [makeResult("README.md", worktreeID: worktree.id)]
    let clock = TestClock()
    let store = TestStore(initialState: FileSearchFeature.State()) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileSearchClient = FileSearchClient { _, _, _ in stub }
    }

    let roots = [makeRoot(worktree)]
    await store.send(.present(selectedWorktreeID: worktree.id, roots: roots)) {
      $0.isPresented = true
      $0.selectedWorktreeID = worktree.id
      $0.roots = roots
      $0.query = ""
      $0.results = []
      $0.selectedIndex = nil
    }

    await clock.advance(by: .milliseconds(150))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
  }

  // MARK: - Worktree-scope searches only the selected root.

  @Test func worktreeScopeSearchesOnlySelectedRoot() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let selected = makeWorktree(path: "/tmp/repo-a")
    let other = makeWorktree(path: "/tmp/repo-b")
    let stub = [makeResult("App.swift", worktreeID: selected.id)]
    let clock = TestClock()
    let capturedRoots = LockIsolated<[[FileSearchRoot]]>([])
    let store = TestStore(initialState: FileSearchFeature.State()) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileSearchClient = FileSearchClient { _, roots, _ in
        capturedRoots.withValue { $0.append(roots) }
        return stub
      }
    }

    let roots = [makeRoot(selected), makeRoot(other)]
    await store.send(.present(selectedWorktreeID: selected.id, roots: roots)) {
      $0.isPresented = true
      $0.selectedWorktreeID = selected.id
      $0.roots = roots
    }

    await clock.advance(by: .milliseconds(150))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
    // Worktree scope must pass ONLY the selected worktree's root to the client.
    #expect(capturedRoots.value.last?.map(\.worktreeID) == [selected.id])
  }

  // MARK: - Scope toggle persists and re-searches across all roots.

  @Test func setScopeGlobalPersistsAndReSearchesAllRoots() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let selected = makeWorktree(path: "/tmp/repo-a")
    let other = makeWorktree(path: "/tmp/repo-b")
    let globalStub = [
      makeResult("App.swift", worktreeID: selected.id),
      makeResult("App.swift", worktreeID: other.id),
    ]
    let clock = TestClock()
    let capturedRoots = LockIsolated<[[FileSearchRoot]]>([])
    let roots = [makeRoot(selected), makeRoot(other)]
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = selected.id
    state.roots = roots
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileSearchClient = FileSearchClient { _, searchRoots, _ in
        capturedRoots.withValue { $0.append(searchRoots) }
        return globalStub
      }
    }

    await store.send(.setScope(.global)) {
      $0.$scopeRawValue.withLock { $0 = "global" }
      $0.selectedIndex = nil
    }

    await clock.advance(by: .milliseconds(150))
    await store.receive(\.searchResponse) {
      $0.results = globalStub
      $0.selectedIndex = 0
    }
    // Global scope passes EVERY root to the client.
    #expect(capturedRoots.value.last?.map(\.worktreeID) == [selected.id, other.id])
    // Scope persisted to the AppStorage-backed shared value (the TestStore routes
    // `@Shared(.appStorage)` to an ephemeral test store, not `UserDefaults.standard`).
    #expect(store.state.scope == .global)
    #expect(store.state.scopeRawValue == "global")
  }

  // MARK: - Global result opens in its own worktree.

  @Test func activateGlobalResultOpensInResultWorktree() async {
    let selected = makeWorktree(path: "/tmp/repo-a")
    let other = makeWorktree(path: "/tmp/repo-b")
    // The result belongs to `other`, not the session's selected worktree.
    let result = makeResult("App.swift", worktreeID: other.id)
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = selected.id
    state.roots = [makeRoot(selected), makeRoot(other)]
    state.results = [result]
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    }

    await store.send(.activate(result)) {
      $0.isPresented = false
    }
    // The delegate must carry the RESULT's worktree (`other`), not the session's
    // selected worktree (`selected`).
    await store.receive(.delegate(.openFile(url: result.absoluteURL, worktreeID: other.id)))
  }

  // MARK: - Debounced query search.

  @Test func queryChangeDebouncesAndSearches() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let stub = [
      makeResult("src/App.swift", worktreeID: worktree.id),
      makeResult("src/Util.swift", worktreeID: worktree.id),
    ]
    let clock = TestClock()
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileSearchClient = FileSearchClient { _, _, _ in stub }
    }

    await store.send(.binding(.set(\.query, "app"))) {
      $0.query = "app"
    }

    await clock.advance(by: .milliseconds(150))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
  }

  @Test func flagOffDoesNotSearch() async {
    setQuickSearch(false)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let clock = TestClock()
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      // Would record an issue if ever invoked; flag-off must not search.
      $0.fileSearchClient = FileSearchClient { _, _, _ in
        Issue.record("search should not run while the quickSearch flag is off")
        return []
      }
    }

    await store.send(.binding(.set(\.query, "app"))) {
      $0.query = "app"
    }
    // No effect to drain; results stay empty.
    await clock.advance(by: .milliseconds(150))
  }

  // MARK: - Selection movement.

  @Test func moveSelectionWrapsAround() async {
    let store = TestStore(initialState: FileSearchFeature.State()) {
      FileSearchFeature()
    }

    await store.send(.moveSelection(.down, itemsCount: 3)) {
      $0.selectedIndex = 0
    }
    await store.send(.moveSelection(.up, itemsCount: 3)) {
      $0.selectedIndex = 2
    }
    await store.send(.moveSelection(.down, itemsCount: 3)) {
      $0.selectedIndex = 0
    }
    await store.send(.moveSelection(.up, itemsCount: 0)) {
      $0.selectedIndex = nil
    }
  }

  // MARK: - Activate.

  @Test func activateEmitsOpenFileDelegate() async {
    let worktree = makeWorktree()
    let result = makeResult("src/App.swift", worktreeID: worktree.id)
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    state.results = [result]
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    }

    await store.send(.activate(result)) {
      $0.isPresented = false
    }
    await store.receive(\.delegate.openFile)
  }

  // MARK: - Dismissal.

  @Test func setPresentedFalseResetsState() async {
    let worktree = makeWorktree()
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.query = "app"
    state.results = [makeResult("a.swift", worktreeID: worktree.id)]
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    }

    await store.send(.setPresented(false)) {
      $0.isPresented = false
      $0.query = ""
      $0.results = []
      $0.selectedIndex = nil
    }
  }

  // MARK: - Helpers.

  private func makeWorktree(path: String = "/tmp/file-search-repo") -> Worktree {
    Worktree(
      id: WorktreeID(path),
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: path)
    )
  }

  private func makeRoot(_ worktree: Worktree) -> FileSearchRoot {
    FileSearchRoot(
      worktreeID: worktree.id,
      url: worktree.localWorkingDirectory!,
      displayName: "Repo / \(worktree.name)"
    )
  }

  private func makeResult(_ relativePath: String, worktreeID: Worktree.ID) -> FileSearchResult {
    FileSearchResult(
      absoluteURL: URL(fileURLWithPath: "\(worktreeID.rawValue)/\(relativePath)"),
      relativePath: relativePath,
      worktreeID: worktreeID,
      rootDisplayName: "Repo / main"
    )
  }

  private func setQuickSearch(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: FeatureFlag.quickSearch.storageKey)
  }

  private func restoreQuickSearch() {
    UserDefaults.standard.removeObject(forKey: FeatureFlag.quickSearch.storageKey)
  }

  private func setScope(_ rawValue: String) {
    UserDefaults.standard.set(rawValue, forKey: "fileSearchScope")
  }

  private func restoreScope() {
    UserDefaults.standard.removeObject(forKey: "fileSearchScope")
  }
}
