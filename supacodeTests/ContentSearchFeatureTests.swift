import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

// Serialized because several cases mutate the process-global `quickSearch`
// `UserDefaults` flag and the persisted `contentSearchScope` AppStorage value;
// parallel execution would race on both.
@MainActor
@Suite(.serialized)
struct ContentSearchFeatureTests {
  // MARK: - Presentation (no auto-search: empty query).

  @Test func presentSetsStateAndDoesNotSearchWithEmptyQuery() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let clock = TestClock()
    let store = TestStore(initialState: ContentSearchFeature.State()) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, _, _, _ in
        Issue.record("content search should not run for an empty query")
        return []
      }
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
    // Empty query → no debounced search fires.
    await clock.advance(by: .milliseconds(200))
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
    let stub = [makeMatch("src/App.swift", line: 3, worktreeID: worktree.id)]
    let clock = TestClock()
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, _, _, _ in stub }
    }

    await store.send(.binding(.set(\.query, "answer"))) {
      $0.query = "answer"
    }
    await clock.advance(by: .milliseconds(200))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
  }

  // MARK: - Flag off → no search.

  @Test func flagOffDoesNotSearch() async {
    setQuickSearch(false)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let clock = TestClock()
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, _, _, _ in
        Issue.record("search should not run while the quickSearch flag is off")
        return []
      }
    }

    await store.send(.binding(.set(\.query, "answer"))) {
      $0.query = "answer"
    }
    // No effect to drain; results stay empty.
    await clock.advance(by: .milliseconds(200))
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
    let stub = [makeMatch("App.swift", line: 1, worktreeID: selected.id)]
    let clock = TestClock()
    let capturedRoots = LockIsolated<[[ContentSearchRoot]]>([])
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = selected.id
    state.roots = [makeRoot(selected), makeRoot(other)]
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, roots, _, _ in
        capturedRoots.withValue { $0.append(roots) }
        return stub
      }
    }

    await store.send(.binding(.set(\.query, "app"))) {
      $0.query = "app"
    }
    await clock.advance(by: .milliseconds(200))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
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
      makeMatch("App.swift", line: 1, worktreeID: selected.id),
      makeMatch("App.swift", line: 1, worktreeID: other.id),
    ]
    let clock = TestClock()
    let capturedRoots = LockIsolated<[[ContentSearchRoot]]>([])
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = selected.id
    state.roots = [makeRoot(selected), makeRoot(other)]
    // A non-empty query so the scope toggle actually re-runs the search.
    state.query = "app"
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, searchRoots, _, _ in
        capturedRoots.withValue { $0.append(searchRoots) }
        return globalStub
      }
    }

    await store.send(.setScope(.global)) {
      $0.$scopeRawValue.withLock { $0 = "global" }
      $0.selectedIndex = nil
    }
    await clock.advance(by: .milliseconds(200))
    await store.receive(\.searchResponse) {
      $0.results = globalStub
      $0.selectedIndex = 0
    }
    #expect(capturedRoots.value.last?.map(\.worktreeID) == [selected.id, other.id])
    #expect(store.state.scope == .global)
    #expect(store.state.scopeRawValue == "global")
  }

  // MARK: - Options toggle re-searches.

  @Test func setCaseSensitiveReSearches() async {
    setQuickSearch(true)
    setScope("worktree")
    defer {
      restoreQuickSearch()
      restoreScope()
    }

    let worktree = makeWorktree()
    let stub = [makeMatch("a.txt", line: 1, worktreeID: worktree.id)]
    let clock = TestClock()
    let capturedOptions = LockIsolated<[ContentSearchOptions]>([])
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = worktree.id
    state.roots = [makeRoot(worktree)]
    state.query = "Hello"
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentSearchClient = ContentSearchClient { _, _, options, _ in
        capturedOptions.withValue { $0.append(options) }
        return stub
      }
    }

    await store.send(.setCaseSensitive(true)) {
      $0.options.caseSensitive = true
      $0.selectedIndex = nil
    }
    await clock.advance(by: .milliseconds(200))
    await store.receive(\.searchResponse) {
      $0.results = stub
      $0.selectedIndex = 0
    }
    #expect(capturedOptions.value.last?.caseSensitive == true)
  }

  // MARK: - Activate emits openMatch with the result's worktree + line.

  @Test func activateEmitsOpenMatchDelegate() async {
    let selected = makeWorktree(path: "/tmp/repo-a")
    let other = makeWorktree(path: "/tmp/repo-b")
    // The match belongs to `other`, not the session's selected worktree.
    let match = makeMatch("App.swift", line: 17, worktreeID: other.id)
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.selectedWorktreeID = selected.id
    state.roots = [makeRoot(selected), makeRoot(other)]
    state.results = [match]
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    }

    await store.send(.activate(match)) {
      $0.isPresented = false
    }
    await store.receive(
      .delegate(.openMatch(fileURL: match.fileURL, line: 17, worktreeID: other.id))
    )
  }

  // MARK: - Dismissal resets state.

  @Test func setPresentedFalseResetsState() async {
    let worktree = makeWorktree()
    var state = ContentSearchFeature.State()
    state.isPresented = true
    state.query = "app"
    state.results = [makeMatch("a.swift", line: 1, worktreeID: worktree.id)]
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      ContentSearchFeature()
    }

    await store.send(.setPresented(false)) {
      $0.isPresented = false
      $0.query = ""
      $0.results = []
      $0.selectedIndex = nil
    }
  }

  // MARK: - Helpers.

  private func makeWorktree(path: String = "/tmp/content-search-repo") -> Worktree {
    Worktree(
      id: WorktreeID(path),
      kind: .git,
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: path)
    )
  }

  private func makeRoot(_ worktree: Worktree) -> ContentSearchRoot {
    ContentSearchRoot(
      worktreeID: worktree.id,
      url: worktree.localWorkingDirectory!,
      displayName: "Repo / \(worktree.name)",
      isGitRepository: true
    )
  }

  private func makeMatch(_ relativePath: String, line: Int, worktreeID: Worktree.ID) -> ContentMatch {
    ContentMatch(
      worktreeID: worktreeID,
      fileURL: URL(fileURLWithPath: "\(worktreeID.rawValue)/\(relativePath)"),
      relativePath: relativePath,
      line: line,
      lineText: "matched line text",
      matchRange: NSRange(location: 0, length: 7),
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
    UserDefaults.standard.set(rawValue, forKey: "contentSearchScope")
  }

  private func restoreScope() {
    UserDefaults.standard.removeObject(forKey: "contentSearchScope")
  }
}
