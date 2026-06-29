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
    let store = TestStore(initialState: EditorFeature.State(id: Self.fixedID, fileURL: URL(filePath: "/tmp/a.txt"))) {
      EditorFeature()
    }

    await store.send(.textChanged("hello")) {
      $0.text = "hello"
      $0.isDirty = true
    }
    await store.receive(\.delegate.dirtyChanged)

    // A second edit keeps it dirty and does NOT re-emit the delegate.
    await store.send(.textChanged("hello world")) {
      $0.text = "hello world"
    }
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
}
