import ComposableArchitecture
import SwiftUI

/// Opens the dedicated editor window when `store.editor` becomes present.
/// Mirrors `OpenSettingsOnSelection`: applied to the main window content so the
/// `openWindow` environment action is always available. Watches the editor's
/// stable `id` (not the whole state) so per-keystroke edits don't re-trigger the
/// window open — only a fresh presentation does.
private struct OpenEditorWindowOnPresentation: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .onChange(of: store.editor?.id) { _, new in
        guard new != nil else { return }
        openWindow(id: WindowID.editor)
      }
  }
}

extension View {
  func openEditorWindowOnPresentation(store: StoreOf<AppFeature>) -> some View {
    modifier(OpenEditorWindowOnPresentation(store: store))
  }
}
