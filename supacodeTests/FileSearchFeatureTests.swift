import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

// Serialized because several cases mutate the process-global `quickSearch`
// `UserDefaults` flag; parallel execution would race on it.
@MainActor
@Suite(.serialized)
struct FileSearchFeatureTests {
  // MARK: - Presentation.

  @Test func presentSetsStateAndTriggersInitialSearch() async {
    setQuickSearch(true)
    defer { restoreQuickSearch() }

    let worktree = makeWorktree()
    let stub = [makeResult("README.md")]
    let clock = TestClock()
    let store = TestStore(initialState: FileSearchFeature.State()) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileSearchClient = FileSearchClient { _, _, _ in stub }
    }

    let root = worktree.localWorkingDirectory!
    await store.send(.present(worktreeID: worktree.id, rootURL: root)) {
      $0.isPresented = true
      $0.worktreeID = worktree.id
      $0.rootURL = root
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

  // MARK: - Debounced query search.

  @Test func queryChangeDebouncesAndSearches() async {
    setQuickSearch(true)
    defer { restoreQuickSearch() }

    let worktree = makeWorktree()
    let root = worktree.localWorkingDirectory!
    let stub = [makeResult("src/App.swift"), makeResult("src/Util.swift")]
    let clock = TestClock()
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.worktreeID = worktree.id
    state.rootURL = root
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
    defer { restoreQuickSearch() }

    let worktree = makeWorktree()
    let root = worktree.localWorkingDirectory!
    let clock = TestClock()
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.worktreeID = worktree.id
    state.rootURL = root
    let store = TestStore(initialState: state) {
      FileSearchFeature()
    } withDependencies: {
      $0.continuousClock = clock
      // Would crash via unimplemented if ever invoked; flag-off must not search.
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
    let result = makeResult("src/App.swift")
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.worktreeID = worktree.id
    state.rootURL = worktree.localWorkingDirectory
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
    var state = FileSearchFeature.State()
    state.isPresented = true
    state.query = "app"
    state.results = [makeResult("a.swift")]
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

  private func makeWorktree() -> Worktree {
    let path = "/tmp/file-search-repo"
    return Worktree(
      id: WorktreeID(path),
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: path)
    )
  }

  private func makeResult(_ relativePath: String) -> FileSearchResult {
    FileSearchResult(
      absoluteURL: URL(fileURLWithPath: "/tmp/file-search-repo/\(relativePath)"),
      relativePath: relativePath
    )
  }

  private func setQuickSearch(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: FeatureFlag.quickSearch.storageKey)
  }

  private func restoreQuickSearch() {
    UserDefaults.standard.removeObject(forKey: FeatureFlag.quickSearch.storageKey)
  }
}
