import ComposableArchitecture
import Darwin
import Dispatch
import Foundation
import SupacodeSettingsShared

nonisolated private let fileWatchLogger = SupaLogger("FileWatchClient")

/// Watches a single file for external on-disk modifications (another process /
/// editor changing it) and emits a `Void` tick on each change. Mirrors the
/// `EditorFileClient` / `WorktreeInfoWatcherClient` dependency shape: a struct of
/// `@Sendable` closures plus a `DependencyKey` conformance so reducers can inject
/// a controllable stream in tests.
///
/// The live implementation uses a `DispatchSource` vnode source on an
/// `open(path, O_EVTONLY)` descriptor. A `.rename` / `.delete` (atomic-save
/// editors swap the inode out from under us) tears the source down and re-arms
/// against the path if the file reappears, so a watch survives the common
/// write-to-temp-then-rename pattern. The descriptor is closed on cancellation
/// (stream termination), so nothing leaks when the editor tab closes or re-opens
/// a different file.
///
/// Gated upstream behind `FeatureFlag.editorView`; nothing here touches the flag
/// because the only caller (the editor feature) is itself reachable only when
/// the flag is on.
struct FileWatchClient: Sendable {
  /// Emit a `Void` element whenever the file at `url` changes on disk. The
  /// returned stream runs until the consumer terminates it (cancels the
  /// subscribing task), at which point the underlying vnode source and
  /// descriptor are torn down. `nonisolated` so callers in nonisolated contexts
  /// (the reducer's `.run` operation, the live-watch test) can read and invoke
  /// it without the target's MainActor default getting in the way.
  nonisolated var watch: @Sendable (_ url: URL) -> AsyncStream<Void>
}

extension FileWatchClient: DependencyKey {
  /// Best-effort delay before re-arming a watch after the file is renamed /
  /// deleted (atomic saves replace the inode). Gives the replacement file a beat
  /// to land before we re-`open` the path.
  nonisolated static let rearmDelay: Duration = .milliseconds(100)

  /// Number of re-arm attempts after a rename / delete before giving up. An
  /// atomic save usually lands within the first retry; a genuine delete falls
  /// through after the budget is spent.
  nonisolated static let rearmAttempts = 20

  nonisolated static let liveValue = FileWatchClient(
    watch: { url in
      AsyncStream { continuation in
        let watcher = Watcher(url: url) {
          continuation.yield()
        }
        continuation.onTermination = { _ in
          watcher.stop()
        }
        watcher.start()
      }
    }
  )

  /// Empty stream that never emits and finishes immediately. Tests that want to
  /// drive external-change behavior override `watch` with a controllable stream
  /// (see `AsyncStream.makeStream`) via `withDependencies`.
  nonisolated static let testValue = FileWatchClient(
    watch: { _ in AsyncStream { $0.finish() } }
  )

  /// Owns one vnode `DispatchSource` for a path and re-arms it across atomic
  /// renames / deletes. A dedicated serial queue serializes the event handler,
  /// re-arm scheduling, and teardown so `stop()` can't race the handler.
  /// `nonisolated` because the target defaults actors to `@MainActor`, but this
  /// type only ever runs on its own serial dispatch queue.
  private nonisolated final class Watcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var rearmWorkItem: DispatchWorkItem?
    private var isStopped = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
      self.url = url
      self.onChange = onChange
      self.queue = DispatchQueue(label: "app.supabit.supacode.file-watch")
    }

    func start() {
      queue.async { [self] in
        arm(remainingRearmAttempts: FileWatchClient.rearmAttempts)
      }
    }

    func stop() {
      queue.async { [self] in
        isStopped = true
        rearmWorkItem?.cancel()
        rearmWorkItem = nil
        // Cancelling the source fires its cancel handler, which closes the fd.
        source?.cancel()
        source = nil
      }
    }

    /// Open the path `O_EVTONLY` and install a vnode source. On a `.rename` /
    /// `.delete` we tear down and schedule a re-arm (the inode is gone, so the
    /// old descriptor stops delivering). On a `.write` / `.extend` we emit.
    private func arm(remainingRearmAttempts: Int) {
      guard !isStopped else { return }
      let path = url.path(percentEncoded: false)
      let fileDescriptor = open(path, O_EVTONLY)
      guard fileDescriptor >= 0 else {
        // File not present (yet). Re-arm against the path if we still have budget
        // — covers a delete + recreate by an external editor.
        scheduleRearm(remainingRearmAttempts: remainingRearmAttempts)
        return
      }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fileDescriptor,
        eventMask: [.write, .extend, .rename, .delete],
        queue: queue
      )
      source.setEventHandler { [weak self, weak source] in
        guard let self, let source else { return }
        let event = source.data
        if event.contains(.delete) || event.contains(.rename) {
          // Inode swapped out (atomic save) or removed. Drop this source and
          // re-arm against the path. Emit too: the on-disk contents changed.
          source.cancel()
          self.source = nil
          self.onChange()
          self.scheduleRearm(remainingRearmAttempts: FileWatchClient.rearmAttempts)
          return
        }
        self.onChange()
      }
      source.setCancelHandler {
        close(fileDescriptor)
      }
      self.source = source
      source.resume()
    }

    private func scheduleRearm(remainingRearmAttempts: Int) {
      guard !isStopped, remainingRearmAttempts > 0 else {
        if remainingRearmAttempts <= 0 {
          fileWatchLogger.debug("Gave up re-arming watch for \(self.url.lastPathComponent)")
        }
        return
      }
      rearmWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.arm(remainingRearmAttempts: remainingRearmAttempts - 1)
      }
      rearmWorkItem = workItem
      queue.asyncAfter(deadline: .now() + FileWatchClient.rearmDelay.timeInterval, execute: workItem)
    }
  }
}

extension DependencyValues {
  nonisolated var fileWatchClient: FileWatchClient {
    get { self[FileWatchClient.self] }
    set { self[FileWatchClient.self] = newValue }
  }
}

extension Duration {
  /// Seconds as a `TimeInterval` for bridging to `DispatchQueue.asyncAfter`.
  fileprivate nonisolated var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
