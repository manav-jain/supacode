import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let editorFileLogger = SupaLogger("EditorFileClient")

/// Reading / writing the on-disk contents of a single file for the in-app
/// editor. Mirrors the `WorkspaceClient` / `FileSearchClient` dependency shape: a
/// struct of `@Sendable` closures plus a `DependencyKey` conformance so reducers
/// can inject a stub in tests. Gated upstream behind `FeatureFlag.editorView`;
/// nothing here touches the flag because the only callers (the editor feature)
/// are themselves reachable only when the flag is on.
struct EditorFileClient: Sendable {
  /// Read a UTF-8 file at `url` into a `String`. Throws `EditorFileError` for a
  /// missing file, an over-size file (the large-file guard), or a decode
  /// failure.
  var read: @Sendable (_ url: URL) async throws -> String
  /// Write `text` to `url` atomically as UTF-8.
  var write: @Sendable (_ text: String, _ url: URL) async throws -> Void
}

/// Errors surfaced by `EditorFileClient`. `Equatable` so the reducer's
/// `loadFailed(String)` copy can be derived deterministically in tests.
enum EditorFileError: Error, Equatable, LocalizedError {
  /// The file exceeds `EditorFileClient.maxFileByteCount` and is refused so the
  /// editor never tries to load a multi-hundred-MB blob into memory.
  case fileTooLarge(byteCount: Int, limit: Int)
  /// The file's bytes are not valid UTF-8.
  case notUTF8

  var errorDescription: String? {
    switch self {
    case .fileTooLarge(let byteCount, let limit):
      "File is too large to open (\(byteCount) bytes; limit \(limit) bytes)."
    case .notUTF8:
      "File is not valid UTF-8 text."
    }
  }
}

extension EditorFileClient: DependencyKey {
  /// Largest file the editor will read. ~5 MB — generous for source files while
  /// still refusing accidental binaries / huge logs that would balloon memory.
  nonisolated static let maxFileByteCount = 5 * 1024 * 1024

  nonisolated static let liveValue = EditorFileClient(
    read: { url in
      // Guard on the declared file size BEFORE reading so an over-size file is
      // never pulled into memory. `.fileSizeKey` is cheap; fall through (read
      // and re-check the loaded byte count) if it is unavailable.
      let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
      if let declaredSize = resourceValues?.fileSize, declaredSize > Self.maxFileByteCount {
        editorFileLogger.warning(
          "Refusing to open over-size file \(url.lastPathComponent) (\(declaredSize) bytes)")
        throw EditorFileError.fileTooLarge(byteCount: declaredSize, limit: Self.maxFileByteCount)
      }
      let data = try Data(contentsOf: url)
      if data.count > Self.maxFileByteCount {
        editorFileLogger.warning(
          "Refusing to open over-size file \(url.lastPathComponent) (\(data.count) bytes)")
        throw EditorFileError.fileTooLarge(byteCount: data.count, limit: Self.maxFileByteCount)
      }
      guard let text = String(data: data, encoding: .utf8) else {
        throw EditorFileError.notUTF8
      }
      return text
    },
    write: { text, url in
      try Data(text.utf8).write(to: url, options: [.atomic])
    }
  )

  nonisolated static let testValue = EditorFileClient(
    read: unimplemented("EditorFileClient.read", placeholder: ""),
    write: unimplemented("EditorFileClient.write")
  )
}

extension DependencyValues {
  nonisolated var editorFileClient: EditorFileClient {
    get { self[EditorFileClient.self] }
    set { self[EditorFileClient.self] = newValue }
  }
}
