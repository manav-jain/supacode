import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct EditorFeatureTests {
  private static let fixedID = UUID(0)

  // MARK: - Open → load.

  @Test func openLoadsFileAndClearsDirty() async {
    let url = URL(filePath: "/tmp/example.swift")
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID)) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in "let x = 1\n" }
    }

    await store.send(.open(url)) {
      $0.fileURL = url
      $0.loadError = nil
      $0.isLoading = true
    }
    await store.receive(\.fileLoaded) {
      $0.text = "let x = 1\n"
      $0.isLoading = false
      $0.loadError = nil
    }
  }

  // MARK: - Editing marks dirty and emits the delegate exactly once.

  @Test func textChangedMarksDirtyAndEmitsDelegate() async {
    let url = URL(filePath: "/tmp/a.txt")
    let clock = TestClock()
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID, fileURL: url)) {
      EditorFeature()
    } withDependencies: {
      // A fileURL is set, so each edit arms the auto-save debounce; pin the clock
      // so the in-flight timer is deterministic.
      $0.continuousClock = clock
      $0.editorFileClient.write = { _, _ in }
    }

    await store.send(.textChanged("hello")) {
      $0.text = "hello"
      $0.isDirty = true
    }
    await store.receive(\.delegate.dirtyChanged)

    // A second edit keeps it dirty and does NOT re-emit the delegate. It also
    // cancels-in-flight the prior auto-save timer and arms a fresh one.
    await store.send(.textChanged("hello world")) {
      $0.text = "hello world"
    }

    // Drain the pending auto-save timer: advancing past the debounce fires the
    // save, which clears dirty.
    await clock.advance(by: .milliseconds(1500))
    await store.receive(\.autoSaveFired)
    await store.receive(\.save)
    await store.receive(\.saved) {
      $0.isDirty = false
    }
    await store.receive(\.delegate.dirtyChanged)
  }

  // MARK: - Save clears dirty.

  @Test func saveWritesAndClearsDirty() async {
    let url = URL(filePath: "/tmp/save.txt")
    let written = LockIsolated<(String, URL)?>(nil)
    let store = TestStore(
      initialState: EditorFeature.State(id: Self.fixedID, fileURL: url, text: "draft", isDirty: true)
    ) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.write = { text, url in written.setValue((text, url)) }
    }

    await store.send(.save)
    await store.receive(\.saved) {
      $0.isDirty = false
    }
    await store.receive(\.delegate.dirtyChanged)

    #expect(written.value?.0 == "draft")
    #expect(written.value?.1 == url)
  }

  @Test func saveNoOpsWithoutFileURL() async {
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID, text: "draft", isDirty: true)) {
      EditorFeature()
    }
    // No fileURL → save must not call the client or emit any action.
    await store.send(.save)
  }

  // MARK: - Load failure surfaces an error.

  @Test func loadFailedSetsLoadError() async {
    let url = URL(filePath: "/tmp/missing.txt")
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID)) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in throw EditorFileError.notUTF8 }
    }

    await store.send(.open(url)) {
      $0.fileURL = url
      $0.isLoading = true
    }
    await store.receive(\.loadFailed) {
      $0.isLoading = false
      $0.loadError = EditorFileError.notUTF8.localizedDescription
    }
  }

  // MARK: - Save failure leaves dirty intact.

  @Test func saveFailedKeepsDirty() async {
    let url = URL(filePath: "/tmp/ro.txt")
    let store = TestStore(
      initialState: EditorFeature.State(id: Self.fixedID, fileURL: url, text: "draft", isDirty: true)
    ) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.write = { _, _ in throw EditorFileError.notUTF8 }
    }

    await store.send(.save)
    await store.receive(\.saveFailed)
    // isDirty stays true (no state change asserted), no dirtyChanged delegate.
  }

  // MARK: - External change while CLEAN reloads the buffer.

  @Test func externalChangeWhileCleanReloads() async {
    let url = URL(filePath: "/tmp/watched.txt")
    let store = TestStore(
      initialState: EditorFeature.State(id: Self.fixedID, fileURL: url, text: "original", isDirty: false)
    ) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in "updated on disk" }
    }

    // Simulate the watcher firing. The re-read sees new on-disk contents that
    // differ from the (clean) buffer, so we silently reload.
    await store.send(.externalChange)
    await store.receive(\.externalChangeResolved) {
      $0.text = "updated on disk"
    }
  }

  // MARK: - External change while DIRTY raises the conflict flag (no clobber).

  @Test func externalChangeWhileDirtyRaisesConflict() async {
    let url = URL(filePath: "/tmp/watched.txt")
    let store = TestStore(
      initialState: EditorFeature.State(id: Self.fixedID, fileURL: url, text: "my local edits", isDirty: true)
    ) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in "someone else changed this" }
    }

    await store.send(.externalChange)
    await store.receive(\.externalChangeResolved) {
      // Buffer is preserved; only the conflict flag flips.
      $0.externallyModified = true
    }
    #expect(store.state.text == "my local edits")
    #expect(store.state.isDirty == true)
  }

  // MARK: - Self-write suppression: our own save must not trigger a reload.

  @Test func selfWriteDoesNotTriggerReload() async {
    let url = URL(filePath: "/tmp/watched.txt")
    let store = TestStore(
      // Clean buffer whose contents already match what is on disk (i.e. we just
      // saved "my saved text").
      initialState: EditorFeature.State(id: Self.fixedID, fileURL: url, text: "my saved text", isDirty: false)
    ) {
      EditorFeature()
    } withDependencies: {
      // The re-read returns exactly the buffer contents — this is our own write.
      $0.editorFileClient.read = { _ in "my saved text" }
    }

    await store.send(.externalChange)
    // Disk matches the buffer → resolved is a no-op (no text change, no flag).
    await store.receive(\.externalChangeResolved)
    #expect(store.state.text == "my saved text")
    #expect(store.state.externallyModified == false)
    #expect(store.state.isDirty == false)
  }

  // MARK: - Resolve a conflict by reloading from disk.

  @Test func reloadFromDiskClearsFlagAndReloads() async {
    let url = URL(filePath: "/tmp/watched.txt")
    let store = TestStore(
      initialState: EditorFeature.State(
        id: Self.fixedID,
        fileURL: url,
        text: "my local edits",
        isDirty: true,
        externallyModified: true
      )
    ) {
      EditorFeature()
    } withDependencies: {
      $0.editorFileClient.read = { _ in "disk wins" }
    }

    await store.send(.reloadFromDisk) {
      $0.externallyModified = false
      $0.isLoading = true
    }
    await store.receive(\.fileLoaded) {
      $0.text = "disk wins"
      $0.isLoading = false
      $0.isDirty = false
    }
    await store.receive(\.delegate.dirtyChanged)
  }

  // MARK: - Resolve a conflict by keeping local changes.

  @Test func keepLocalChangesClearsFlagAndKeepsBuffer() async {
    let url = URL(filePath: "/tmp/watched.txt")
    let store = TestStore(
      initialState: EditorFeature.State(
        id: Self.fixedID,
        fileURL: url,
        text: "my local edits",
        isDirty: true,
        externallyModified: true
      )
    ) {
      EditorFeature()
    }

    await store.send(.keepLocalChanges) {
      $0.externallyModified = false
    }
    // Buffer and dirty state untouched.
    #expect(store.state.text == "my local edits")
    #expect(store.state.isDirty == true)
  }

  // MARK: - Auto-save fires after the debounce.

  @Test func autoSaveFiresAfterDebounce() async {
    let url = URL(filePath: "/tmp/autosave.txt")
    let clock = TestClock()
    let written = LockIsolated<String?>(nil)
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID, fileURL: url)) {
      EditorFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.editorFileClient.write = { text, _ in written.setValue(text) }
    }

    await store.send(.textChanged("auto")) {
      $0.text = "auto"
      $0.isDirty = true
    }
    await store.receive(\.delegate.dirtyChanged)

    // Nothing fires before the debounce elapses.
    await clock.advance(by: .milliseconds(1499))
    // One tick past the window → auto-save runs.
    await clock.advance(by: .milliseconds(1))
    await store.receive(\.autoSaveFired)
    await store.receive(\.save)
    await store.receive(\.saved) {
      $0.isDirty = false
    }
    await store.receive(\.delegate.dirtyChanged)

    #expect(written.value == "auto")
  }

  // MARK: - No auto-save without a fileURL.

  @Test func noAutoSaveWithoutFileURL() async {
    let clock = TestClock()
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID)) {
      EditorFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.textChanged("orphan")) {
      $0.text = "orphan"
      $0.isDirty = true
    }
    await store.receive(\.delegate.dirtyChanged)

    // No fileURL → no auto-save effect was scheduled, so advancing does nothing.
    await clock.advance(by: .seconds(5))
  }

  // MARK: - No auto-save into an unresolved conflict.

  @Test func noAutoSaveWhileExternallyModified() async {
    let url = URL(filePath: "/tmp/conflict.txt")
    let clock = TestClock()
    let store = TestStore(
      initialState: EditorFeature.State(
        id: Self.fixedID,
        fileURL: url,
        text: "local",
        isDirty: true,
        externallyModified: true
      )
    ) {
      EditorFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    // Dirty + externallyModified: editing must NOT arm the auto-save debounce
    // (auto-saving into a conflict would silently overwrite the on-disk change),
    // so advancing past the window produces no actions at all.
    await store.send(.textChanged("local edited")) {
      $0.text = "local edited"
    }
    await clock.advance(by: .milliseconds(1500))
    // No `.autoSaveFired` and no `.save` — nothing was scheduled.
  }
}
