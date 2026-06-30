import SwiftTreeSitter
import TreeSitterSwift

// Phase 5 dependency probe: confirms SwiftTreeSitter + the TreeSitterSwift grammar
// resolve, compile, and link under the project toolchain. Replaced by the real
// syntax highlighter / symbol extractor in the Phase 5 implementation.
enum HighlightingDependencyProbe {
  static let moduleLinked = true
}
