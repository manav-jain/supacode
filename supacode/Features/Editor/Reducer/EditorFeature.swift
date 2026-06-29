import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let editorLogger = SupaLogger("Editor")

/// A single in-app editor surface: load a file, edit its text, save it back.
/// v1 is plain editing + open/save — NO syntax highlighting (that arrives in
/// Phase 5). Gated upstream behind `FeatureFlag.editorView`; the feature is only
/// ever instantiated from the `.supacode` open path, which `OpenWorktreeAction`
/// exposes only when the flag is on.
///
/// `Action` is deliberately `Equatable`, so the file-load result is split into
/// `fileLoaded(String)` / `loadFailed(String)` rather than carrying a
/// non-Equatable `Error`. Same for save with `saved` / `saveFailed`.
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: UUID
    /// The file currently bound to this editor, or `nil` for an empty editor
    /// (the `.supacode` "open the worktree" entry point starts empty).
    var fileURL: URL?
    /// The live buffer contents. Two-way bound to the text view.
    var text: String
    /// True when `text` has diverged from the on-disk contents since the last
    /// load / save. Drives the unsaved-changes affordance in the tab bar.
    var isDirty: Bool
    /// Set when a load fails (missing file, too large, not UTF-8). Surfaced as
    /// an inline error state instead of the editor.
    var loadError: String?
    /// True while a `read` is in flight, so the view can show a loading state
    /// and ⌘S no-ops mid-load.
    var isLoading: Bool

    init(
      id: UUID = UUID(),
      fileURL: URL? = nil,
      text: String = "",
      isDirty: Bool = false,
      loadError: String? = nil,
      isLoading: Bool = false
    ) {
      self.id = id
      self.fileURL = fileURL
      self.text = text
      self.isDirty = isDirty
      self.loadError = loadError
      self.isLoading = isLoading
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    /// Open `url`, kicking off an async read.
    case open(URL)
    /// The text view edited the buffer. Marks the editor dirty.
    case textChanged(String)
    /// Async read succeeded with the file's contents.
    case fileLoaded(String)
    /// Async read failed; `message` is a user-facing description.
    case loadFailed(String)
    /// Explicit save (⌘S).
    case save
    /// Async write succeeded.
    case saved
    /// Async write failed; `message` is a user-facing description.
    case saveFailed(String)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// The dirty state flipped. The tab owner uses this to show / hide the
    /// unsaved-changes dot on the editor tab.
    case dirtyChanged(Bool)
  }

  private nonisolated enum CancelID: Hashable {
    case load(UUID)
    case save(UUID)
  }

  @Dependency(\.editorFileClient) private var editorFileClient

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.text):
        // Two-way text binding edits flow through here. Treat as a content edit.
        return Self.markDirty(&state, dirty: true)

      case .binding:
        return .none

      case .open(let url):
        state.fileURL = url
        state.loadError = nil
        state.isLoading = true
        let editorID = state.id
        return .run { send in
          do {
            let text = try await editorFileClient.read(url)
            await send(.fileLoaded(text))
          } catch {
            await send(.loadFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.load(editorID), cancelInFlight: true)

      case .textChanged(let text):
        state.text = text
        return Self.markDirty(&state, dirty: true)

      case .fileLoaded(let text):
        state.text = text
        state.isLoading = false
        state.loadError = nil
        return Self.markDirty(&state, dirty: false)

      case .loadFailed(let message):
        state.isLoading = false
        state.loadError = message
        editorLogger.warning("Failed to load \(state.fileURL?.lastPathComponent ?? "<none>"): \(message)")
        return .none

      case .save:
        // Nothing to save without a destination or while a load is still in
        // flight (the buffer isn't authoritative yet).
        guard let url = state.fileURL, !state.isLoading else { return .none }
        let text = state.text
        let editorID = state.id
        return .run { send in
          do {
            try await editorFileClient.write(text, url)
            await send(.saved)
          } catch {
            await send(.saveFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.save(editorID), cancelInFlight: true)

      case .saved:
        return Self.markDirty(&state, dirty: false)

      case .saveFailed(let message):
        editorLogger.warning("Failed to save \(state.fileURL?.lastPathComponent ?? "<none>"): \(message)")
        return .none

      case .delegate:
        return .none
      }
    }
  }

  /// Set `isDirty` and emit `delegate(.dirtyChanged)` only when it actually
  /// flips, so a no-op edit (e.g. re-setting identical text) doesn't churn the
  /// tab bar.
  private static func markDirty(_ state: inout State, dirty: Bool) -> Effect<Action> {
    guard state.isDirty != dirty else { return .none }
    state.isDirty = dirty
    return .send(.delegate(.dirtyChanged(dirty)))
  }
}
