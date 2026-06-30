import Foundation
import Testing

@testable import supacode

struct EditorFileClientTests {
  @Test func readWriteRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EditorFileClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "round-trip.txt")
    let client = EditorFileClient.liveValue
    let contents = "line one\nline two\nüñîçødé 🎉\n"

    try await client.write(contents, url)
    let readBack = try await client.read(url)

    #expect(readBack == contents)
  }

  @Test func writeOverwritesExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EditorFileClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "overwrite.txt")
    let client = EditorFileClient.liveValue

    try await client.write("first", url)
    try await client.write("second", url)
    let readBack = try await client.read(url)

    #expect(readBack == "second")
  }

  @Test func readRefusesOverSizeFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EditorFileClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "huge.bin")
    // One byte over the limit.
    let bytes = Data(count: EditorFileClient.maxFileByteCount + 1)
    try bytes.write(to: url)

    let client = EditorFileClient.liveValue
    await #expect(throws: EditorFileError.self) {
      _ = try await client.read(url)
    }
  }

  @Test func readRefusesNonUTF8File() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EditorFileClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "binary.bin")
    // Invalid UTF-8 byte sequence.
    try Data([0xFF, 0xFE, 0xFD]).write(to: url)

    let client = EditorFileClient.liveValue
    await #expect(throws: EditorFileError.notUTF8) {
      _ = try await client.read(url)
    }
  }
}

/// Live `FileWatchClient` coverage. The reducer-level behavior (clean reload,
/// dirty conflict, self-write suppression) is covered deterministically in
/// `EditorFeatureTests` with an injected stream; this verifies the live vnode
/// source actually delivers an event for a real on-disk write, with a generous
/// timeout so it doesn't depend on tight timing.
struct FileWatchClientTests {
  @Test nonisolated func liveWatchEmitsOnDiskWrite() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "FileWatchClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "watched.txt")
    try Data("initial".utf8).write(to: url)

    // Capture the `@Sendable` watch closure as a value so it crosses into the
    // task group's nonisolated closures (the struct property itself is isolated
    // under the target's MainActor default).
    let watch = FileWatchClient.liveValue.watch

    // Race the watcher's first emission against a generous timeout. The writer
    // task polls/writes until the watcher fires (or the timeout wins), so a
    // slow filesystem retries rather than flaking on a single missed write.
    let received = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in watch(url) {
          return true
        }
        return false
      }
      group.addTask {
        for _ in 0..<40 {
          try? await Task.sleep(for: .milliseconds(100))
          try? Data("changed-\(UUID().uuidString)".utf8).write(to: url)
        }
        return false
      }
      // The first task to report `true` (the watcher fired) wins; cancel the rest.
      for await result in group where result {
        group.cancelAll()
        return true
      }
      group.cancelAll()
      return false
    }

    #expect(received)
  }
}
