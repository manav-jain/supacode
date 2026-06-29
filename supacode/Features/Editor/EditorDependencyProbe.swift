import STTextView

// Phase 4a dependency probe: proves `STTextView` resolves, builds, and links
// under the project toolchain (Tuist + Xcode 26.3 + Swift 6 + macOS 26).
// Chosen over CodeEditSourceEditor, whose SwiftLint build-tool plugin hangs SPM
// resolution in this sandbox (and would break reproducible builds). Tree-sitter
// syntax highlighting is layered on in Phase 5 via SwiftTreeSitter.
// Replaced by the real editor surface view in Phase 4b.
enum EditorDependencyProbe {
  static let moduleLinked = true
}
