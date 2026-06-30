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
    /// Set when the file changed on disk *while the buffer was dirty*. The user
    /// has unsaved local edits AND the file moved underneath them, so we can't
    /// silently reload (that would clobber their work). Drives the conflict
    /// banner in `EditorView`; cleared by resolving the conflict (Reload / Keep).
    var externallyModified: Bool
    /// A 1-based line the view should scroll to once the buffer has loaded.
    /// Seeded by a find-in-files open; the view watches it, reveals the line
    /// after the load lands, then clears it via `scrollLineConsumed`. `nil` when
    /// there's no pending jump.
    var pendingScrollLine: Int?

    init(
      id: UUID = UUID(),
      fileURL: URL? = nil,
      text: String = "",
      isDirty: Bool = false,
      loadError: String? = nil,
      isLoading: Bool = false,
      externallyModified: Bool = false,
      pendingScrollLine: Int? = nil
    ) {
      self.id = id
      self.fileURL = fileURL
      self.text = text
      self.isDirty = isDirty
      self.loadError = loadError
      self.isLoading = isLoading
      self.externallyModified = externallyModified
      self.pendingScrollLine = pendingScrollLine
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    /// Open `url`, kicking off an async read.
    case open(URL)
    /// Open `url` and, once loaded, scroll to `line` (1-based). Used by
    /// find-in-files to land the user on the matched line. Re-targeting an
    /// already-open file just updates the pending scroll line and re-reveals.
    case openAtLine(URL, line: Int)
    /// The view consumed `pendingScrollLine` (it scrolled to it). Clears the
    /// pending jump so a later body run doesn't re-scroll.
    case scrollLineConsumed
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
    /// The file watcher observed an external on-disk change. Triggers a re-read
    /// so `externalChangeResolved` can compare disk vs. buffer.
    case externalChange
    /// The re-read after an `externalChange` completed with the current on-disk
    /// contents. Self-write suppression and clean/dirty branching happen here.
    case externalChangeResolved(String)
    /// Resolve a conflict by reloading from disk, discarding local edits.
    case reloadFromDisk
    /// Resolve a conflict by keeping the local buffer; the next save overwrites
    /// disk. Just clears the flag — the buffer stays dirty.
    case keepLocalChanges
    /// Debounced auto-save fired. Re-checks the guards (still dirty, still has a
    /// URL, no unresolved conflict) before delegating to `save`.
    case autoSaveFired
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
    case watch(UUID)
    case autoSave(UUID)
    case externalRead(UUID)
  }

  /// Debounce window after the user stops typing before auto-save fires.
  private static let autoSaveDebounce: Duration = .milliseconds(1500)

  @Dependency(\.editorFileClient) private var editorFileClient
  @Dependency(\.fileWatchClient) private var fileWatchClient
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.text):
        // Two-way text binding edits flow through here. Treat as a content edit
        // and (re)schedule the auto-save debounce.
        return .merge(
          Self.markDirty(&state, dirty: true),
          autoSaveEffect(state: state)
        )

      case .binding:
        return .none

      case .open(let url):
        state.fileURL = url
        state.loadError = nil
        state.isLoading = true
        // A fresh file means any prior conflict is moot.
        state.externallyModified = false
        let editorID = state.id
        return .merge(
          .run { send in
            do {
              let text = try await editorFileClient.read(url)
              await send(.fileLoaded(text))
            } catch {
              await send(.loadFailed(error.localizedDescription))
            }
          }
          .cancellable(id: CancelID.load(editorID), cancelInFlight: true),
          // (Re)start watching this URL; cancelInFlight tears down the previous
          // watch so the old file's DispatchSource is released.
          watchEffect(url: url, editorID: editorID),
          // A new file invalidates any pending auto-save for the old buffer.
          .cancel(id: CancelID.autoSave(editorID))
        )

      case .openAtLine(let url, let line):
        // Seed the pending scroll target so the view jumps to the line once the
        // buffer is ready. If this is the same file already loaded, just update
        // the target (no re-read) — the view's `pendingScrollLine` watcher fires
        // the reveal. Otherwise fall through to `.open`'s load.
        state.pendingScrollLine = max(1, line)
        if state.fileURL == url, !state.isLoading, state.loadError == nil {
          return .none
        }
        return .send(.open(url))

      case .scrollLineConsumed:
        state.pendingScrollLine = nil
        return .none

      case .textChanged(let text):
        state.text = text
        return .merge(
          Self.markDirty(&state, dirty: true),
          autoSaveEffect(state: state)
        )

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

      case .externalChange:
        // The watcher fired. Re-read the current on-disk contents so
        // `externalChangeResolved` can compare them against our buffer — this is
        // what suppresses our own writes (disk will match the buffer we just
        // saved) without relying on a fragile timing window.
        guard let url = state.fileURL else { return .none }
        let editorID = state.id
        return .run { send in
          do {
            let text = try await editorFileClient.read(url)
            await send(.externalChangeResolved(text))
          } catch {
            // A failed re-read (e.g. file deleted mid-rename) is not actionable
            // here; the watcher re-arms and a later event re-triggers the read.
            editorLogger.debug("External-change re-read failed: \(error.localizedDescription)")
          }
        }
        .cancellable(id: CancelID.externalRead(editorID), cancelInFlight: true)

      case .externalChangeResolved(let diskText):
        // Self-write suppression: if disk already matches our buffer, the event
        // was our own save (or a redundant no-op) — do nothing.
        guard diskText != state.text else { return .none }
        if state.isDirty {
          // Unsaved local edits AND the file diverged on disk: don't clobber the
          // user's work. Surface the conflict banner instead.
          state.externallyModified = true
          return .none
        }
        // Clean buffer: safe to silently reload to the on-disk contents.
        state.text = diskText
        state.loadError = nil
        return Self.markDirty(&state, dirty: false)

      case .reloadFromDisk:
        // Resolve the conflict by discarding local edits and re-reading. Clearing
        // the flag first so the banner dismisses immediately.
        state.externallyModified = false
        guard let url = state.fileURL else { return .none }
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

      case .keepLocalChanges:
        // Resolve the conflict by keeping the buffer; the next save overwrites
        // disk. Buffer stays dirty, flag clears.
        state.externallyModified = false
        return .none

      case .autoSaveFired:
        // Re-validate the guards at fire time: still has a destination, still
        // dirty, not loading, and no unresolved external conflict (auto-saving
        // into a conflict would silently overwrite the on-disk changes).
        guard
          state.fileURL != nil,
          state.isDirty,
          !state.isLoading,
          !state.externallyModified
        else { return .none }
        return .send(.save)

      case .delegate:
        return .none
      }
    }
  }

  /// Subscribe to the file watcher for `url`, mapping each on-disk change tick
  /// to an `.externalChange` action. Cancellable + cancel-in-flight keyed on the
  /// editor id so re-opening a different file tears down the previous watch (and
  /// its `DispatchSource`) before arming the new one.
  private func watchEffect(url: URL, editorID: UUID) -> Effect<Action> {
    // Capture the client up front: it's read on the MainActor-isolated reducer,
    // but the `.run` operation runs nonisolated, so it can't touch `self`.
    let fileWatchClient = self.fileWatchClient
    return .run { send in
      for await _ in fileWatchClient.watch(url) {
        await send(.externalChange)
      }
    }
    .cancellable(id: CancelID.watch(editorID), cancelInFlight: true)
  }

  /// Debounced auto-save: after the user stops typing for `autoSaveDebounce`,
  /// fire `.autoSaveFired`, which re-validates the guards before saving. No-ops
  /// (and cancels any pending auto-save) when there's nothing to persist — no
  /// destination, a clean buffer, mid-load, or an unresolved external conflict.
  /// Cancellable + cancel-in-flight so each keystroke resets the timer.
  private func autoSaveEffect(state: State) -> Effect<Action> {
    let editorID = state.id
    guard
      state.fileURL != nil,
      state.isDirty,
      !state.isLoading,
      !state.externallyModified
    else {
      return .cancel(id: CancelID.autoSave(editorID))
    }
    return .run { send in
      try await clock.sleep(for: Self.autoSaveDebounce)
      await send(.autoSaveFired)
    }
    .cancellable(id: CancelID.autoSave(editorID), cancelInFlight: true)
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
