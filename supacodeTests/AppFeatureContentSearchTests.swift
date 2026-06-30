import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

// Serialized because cases toggle the process-global `quickSearch` /
// `editorView` `UserDefaults` flags; parallel execution would race on them.
@MainActor
@Suite(.serialized)
struct AppFeatureContentSearchTests {
  // MARK: - presentContentSearch.

  @Test func presentContentSearchBuildsRootsAndPresents() async {
    setFlag(.quickSearch, true)
    defer { restoreFlag(.quickSearch) }

    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.presentContentSearch)
    await store.receive(\.contentSearch.present) {
      $0.contentSearch.isPresented = true
      $0.contentSearch.selectedWorktreeID = worktree.id
    }
    // The selected worktree's root is included and tagged as a git repository.
    #expect(store.state.contentSearch.roots.map(\.worktreeID) == [worktree.id])
    #expect(store.state.contentSearch.roots.first?.isGitRepository == true)
  }

  @Test func presentContentSearchNoOpsWhenFlagOff() async {
    setFlag(.quickSearch, false)
    defer { restoreFlag(.quickSearch) }

    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    let store = TestStore(initialState: AppFeature.State(repositories: repositoriesState)) {
      AppFeature()
    }

    // Flag off: no `.contentSearch.present` follow-up — nothing to drain.
    await store.send(.presentContentSearch)
  }

  // MARK: - openMatch → open file at line in the Supacode editor.

  @Test func openMatchOpensEditorTabAtLine() async {
    setFlag(.quickSearch, true)
    setFlag(.editorView, true)
    defer {
      restoreFlag(.quickSearch)
      restoreFlag(.editorView)
    }

    let worktree = makeWorktree()
    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    let terminalCommands = LockIsolated<[TerminalClient.Command]>([])
    var state = AppFeature.State(repositories: repositoriesState)
    // Force the Supacode in-app editor as the open target.
    state.openActionSelection = .supacode
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        terminalCommands.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    let fileURL = worktree.localWorkingDirectory!.appending(path: "src/App.swift")
    await store.send(
      .contentSearch(.delegate(.openMatch(fileURL: fileURL, line: 42, worktreeID: worktree.id)))
    )

    // The editor tab is created for the file, carrying the find-in-files line.
    let createEditorCommands = terminalCommands.value.compactMap { command -> (URL?, Int?)? in
      guard case .createEditorTab(_, let url, let line, _) = command else { return nil }
      return (url, line)
    }
    #expect(createEditorCommands.count == 1)
    #expect(createEditorCommands.first?.0 == fileURL)
    #expect(createEditorCommands.first?.1 == 42)
  }

  // MARK: - Helpers.

  private func makeWorktree() -> Worktree {
    let repositoryRootURL = URL(fileURLWithPath: "/tmp/content-repo-\(UUID().uuidString)")
    let worktreeURL = repositoryRootURL.appending(path: "wt-1")
    return Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      name: "wt-1",
      detail: "detail",
      workingDirectory: worktreeURL,
      repositoryRootURL: repositoryRootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: RepositoryID(worktree.repositoryRootURL.path(percentEncoded: false)),
      rootURL: worktree.repositoryRootURL,
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    return repositoriesState
  }

  private func setFlag(_ flag: FeatureFlag, _ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: flag.storageKey)
  }

  private func restoreFlag(_ flag: FeatureFlag) {
    UserDefaults.standard.removeObject(forKey: flag.storageKey)
  }
}
