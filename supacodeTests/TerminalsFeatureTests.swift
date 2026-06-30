import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  @Test func tabProjectionChangedInsertsNewTabThenForwards() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let surface = UUID()
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0
        )
      )
    ) {
      $0.terminalTabs.append(
        TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
      )
    }
    await store.receive(\.terminalTabs)
  }

  @Test func tabRemovedDropsElementAndRecordsForReplayProtection() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: tabID)
      ]
    }
  }

  @Test func staleTabProjectionAfterRemoveDoesNotReinsertPhantomTab() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(
      TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    )
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: tabID)
      ]
    }

    // Late projection arrives after the tab was removed in the same worktree: must NOT re-insert.
    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repo",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [],
          activeSurfaceID: nil,
          unseenNotificationCount: 0
        )
      )
    )

    #expect(store.state.terminalTabs.isEmpty)
  }

  @Test func recentlyRemovedTabIDsAreBoundedByLimit() async {
    let initial = TerminalsFeature.State()
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    // Remove `limit + 5` distinct tab IDs; only the most recent `limit` survive.
    let limit = TerminalsFeature.recentlyRemovedTabLimit
    var allIDs: [TerminalTabID] = []
    for _ in 0..<(limit + 5) {
      let id = TerminalTabID(rawValue: UUID())
      allIDs.append(id)
      await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: id)) {
        $0.recentlyRemovedTabIDs.append(
          TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: id)
        )
        if $0.recentlyRemovedTabIDs.count > limit {
          $0.recentlyRemovedTabIDs.removeFirst($0.recentlyRemovedTabIDs.count - limit)
        }
      }
    }
    #expect(store.state.recentlyRemovedTabIDs.count == limit)
    #expect(store.state.recentlyRemovedTabIDs.first?.tabID == allIDs[5])
    #expect(store.state.recentlyRemovedTabIDs.last?.tabID == allIDs.last)
  }

  @Test func worktreeStateTornDownDrainsTabsAndFIFOForThatWorktree() async {
    // Two worktrees, two tabs each. Tearing down repoA should leave repoB's
    // FIFO + tab features intact.
    let tabA1 = TerminalTabID(rawValue: UUID())
    let tabA2 = TerminalTabID(rawValue: UUID())
    let tabB1 = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA1, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabA2, worktreeID: "/tmp/repoA"))
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabB1, worktreeID: "/tmp/repoB"))
    initial.recentlyRemovedTabIDs = [
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoA", tabID: TerminalTabID(rawValue: UUID())),
      TerminalsFeature.RecentlyRemovedTab(
        worktreeID: "/tmp/repoB", tabID: TerminalTabID(rawValue: UUID())),
    ]
    let repoBRecord = initial.recentlyRemovedTabIDs[1]
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.worktreeStateTornDown(worktreeID: "/tmp/repoA")) {
      $0.recentlyRemovedTabIDs = [repoBRecord]
      $0.terminalTabs.remove(id: tabA1)
      $0.terminalTabs.remove(id: tabA2)
    }
  }

  @Test func sameSessionRestoreAfterTeardownReinsertsTabWithReusedUUID() async {
    // Simulates the snapshot-restore path: tab removed in worktree A, worktree
    // state torn down (FIFO drained for worktreeA), restore replays the same
    // persisted UUID. The reinserted projection must not be shadowed.
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.terminalTabs.append(TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repoA"))
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(.tabRemoved(worktreeID: "/tmp/repoA", tabID: tabID)) {
      $0.terminalTabs.remove(id: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repoA", tabID: tabID)
      ]
    }

    await store.send(.worktreeStateTornDown(worktreeID: "/tmp/repoA")) {
      $0.recentlyRemovedTabIDs = []
    }

    let surface = UUID()
    await store.send(
      .tabProjectionChanged(
        worktreeID: "/tmp/repoA",
        projection: WorktreeTabProjection(
          tabID: tabID,
          surfaceIDs: [surface],
          activeSurfaceID: surface,
          unseenNotificationCount: 0
        )
      )
    ) {
      $0.terminalTabs.append(TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repoA"))
    }
    await store.receive(\.terminalTabs)
  }

  // MARK: - Editor tabs.

  @Test func editorTabOpenedAddsEditorStateAndKicksOffLoad() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let fileURL = URL(filePath: "/tmp/repo/file.swift")
    let store = TestStore(initialState: TerminalsFeature.State()) {
      TerminalsFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in "let x = 1\n" }
    }
    store.exhaustivity = .off

    await store.send(
      .editorTabOpened(worktreeID: "/tmp/repo", tabID: tabID, fileURL: fileURL)
    ) {
      $0.editorTabs.append(EditorFeature.State(id: tabID.rawValue, fileURL: fileURL))
      $0.editorTabWorktreeIDs[tabID] = "/tmp/repo"
    }
    // Forwards `.open(fileURL)` into the scoped editor reducer, which loads.
    await store.receive(\.editorTabs)
    #expect(store.state.editorTabs[id: tabID.rawValue]?.fileURL == fileURL)
  }

  @Test func editorTabOpenedWithNilFileURLAddsEmptyEditorWithoutLoad() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }

    // No `.open` is forwarded for a nil fileURL, so the exhaustive store needs
    // no `receive`.
    await store.send(
      .editorTabOpened(worktreeID: "/tmp/repo", tabID: tabID, fileURL: nil)
    ) {
      $0.editorTabs.append(EditorFeature.State(id: tabID.rawValue, fileURL: nil))
      $0.editorTabWorktreeIDs[tabID] = "/tmp/repo"
    }
  }

  @Test func tabRemovedDropsEditorTabAndWorktreeMapping() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.editorTabs.append(EditorFeature.State(id: tabID.rawValue, fileURL: nil))
    initial.editorTabWorktreeIDs[tabID] = "/tmp/repo"
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID)) {
      $0.editorTabs.remove(id: tabID.rawValue)
      $0.editorTabWorktreeIDs.removeValue(forKey: tabID)
      $0.recentlyRemovedTabIDs = [
        TerminalsFeature.RecentlyRemovedTab(worktreeID: "/tmp/repo", tabID: tabID)
      ]
    }
  }

  @Test func worktreeStateTornDownDropsEditorTabsForThatWorktree() async {
    let editorA = TerminalTabID(rawValue: UUID())
    let editorB = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.editorTabs.append(EditorFeature.State(id: editorA.rawValue, fileURL: nil))
    initial.editorTabs.append(EditorFeature.State(id: editorB.rawValue, fileURL: nil))
    initial.editorTabWorktreeIDs[editorA] = "/tmp/repoA"
    initial.editorTabWorktreeIDs[editorB] = "/tmp/repoB"
    let store = TestStore(initialState: initial) { TerminalsFeature() }

    await store.send(.worktreeStateTornDown(worktreeID: "/tmp/repoA")) {
      $0.editorTabs.remove(id: editorA.rawValue)
      $0.editorTabWorktreeIDs.removeValue(forKey: editorA)
    }
    #expect(store.state.editorTabs[id: editorB.rawValue] != nil)
    #expect(store.state.editorTabWorktreeIDs[editorB] == "/tmp/repoB")
  }

  @Test func staleEditorTabOpenedAfterRemoveDoesNotReinsert() async {
    let tabID = TerminalTabID(rawValue: UUID())
    var initial = TerminalsFeature.State()
    initial.editorTabs.append(EditorFeature.State(id: tabID.rawValue, fileURL: nil))
    initial.editorTabWorktreeIDs[tabID] = "/tmp/repo"
    let store = TestStore(initialState: initial) { TerminalsFeature() }
    store.exhaustivity = .off

    await store.send(.tabRemoved(worktreeID: "/tmp/repo", tabID: tabID))
    // A late editor-open replay for a removed tab in the same worktree must not
    // resurrect the editor state.
    await store.send(
      .editorTabOpened(worktreeID: "/tmp/repo", tabID: tabID, fileURL: nil)
    )
    #expect(store.state.editorTabs.isEmpty)
  }
}
