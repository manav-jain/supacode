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
