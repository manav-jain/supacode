import AppKit
import STTextView
import SwiftUI

/// A thin git change-indicator strip drawn down the leading edge of the editor's
/// text content (Phase 10). STTextView's built-in gutter marker API positions
/// markers *over the line-number cells* (and requires line numbers to be shown,
/// re-laying-out only on viewport relayout), which doesn't fit a passive
/// per-line change strip — so we fall back to a custom floating `NSView` overlay
/// synced to the text view's line geometry. This is the documented fallback when
/// no clean per-line gutter-decoration hook exists.
///
/// The plugin captures the live `STTextView` (the same mechanism `ScrollPlugin`
/// uses) and installs the strip as a horizontal floating subview of the
/// enclosing scroll view, so it stays pinned to the left while the document
/// scrolls underneath. The strip enumerates visible text layout fragments to map
/// each on-screen line to a `y`/`height`, then fills a short colored bar for any
/// line that carries a change kind.
@MainActor
final class EditorGutterStripPlugin: STPlugin {
  /// The strip view. Created lazily on `setUp`.
  private(set) var stripView: EditorGutterStripView?
  private weak var textView: STTextView?
  private var frameObserver: NSObjectProtocol?

  func setUp(context: any Context) {
    let textView = context.textView
    self.textView = textView

    let strip = EditorGutterStripView(textView: textView)
    self.stripView = strip

    if let scrollView = textView.enclosingScrollView {
      scrollView.addFloatingSubview(strip, for: .horizontal)
      // Redraw the bars as the document scrolls / the content view resizes.
      scrollView.contentView.postsBoundsChangedNotifications = true
      frameObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak strip] _ in
        MainActor.assumeIsolated {
          strip?.needsLayout = true
          strip?.needsDisplay = true
        }
      }
    } else {
      textView.addSubview(strip)
    }
    strip.layoutStrip()
  }

  func tearDown() {
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
    }
    frameObserver = nil
    stripView?.removeFromSuperview()
    stripView = nil
    textView = nil
  }

  /// Push the latest per-line change kinds and trigger a redraw. Called by the
  /// view when the editor's `gutterStatus` changes.
  func update(status: [Int: EditorGutterChangeKind]) {
    stripView?.status = status
  }
}

/// The custom strip view that draws the colored change bars. Flipped so `y` runs
/// top-down to match the text view's coordinate space.
@MainActor
final class EditorGutterStripView: NSView {
  /// Per-1-based-line change kind. Setting it triggers a redraw.
  var status: [Int: EditorGutterChangeKind] = [:] {
    didSet {
      guard status != oldValue else { return }
      needsLayout = true
      needsDisplay = true
    }
  }

  /// Width of the strip and of each drawn bar.
  static let stripWidth: CGFloat = 3

  private weak var textView: STTextView?

  init(textView: STTextView) {
    self.textView = textView
    super.init(frame: CGRect(x: 0, y: 0, width: Self.stripWidth, height: 0))
    wantsLayer = true
    // The strip is a passive decoration: it must never intercept clicks meant for
    // the text (selection, caret placement at the line start).
    layer?.zPosition = 1
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  /// Pass through all hit-testing so the strip never steals mouse events.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Keep the strip pinned to the full height of the visible document.
  func layoutStrip() {
    guard let textView, let scrollView = textView.enclosingScrollView else { return }
    let height = scrollView.contentView.bounds.height
    frame = CGRect(x: 0, y: 0, width: Self.stripWidth, height: height)
  }

  override func layout() {
    super.layout()
    layoutStrip()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !status.isEmpty, let textView, let scrollView = textView.enclosingScrollView else { return }

    let layoutManager = textView.textLayoutManager
    guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else { return }

    // Lines before the viewport, so we can number the visible fragments.
    let contentManager = textView.textContentManager
    let elementsBefore = contentManager.textElements(
      for: NSTextRange(location: contentManager.documentRange.location, end: viewportRange.location) ?? viewportRange
    )
    var lineNumber = elementsBefore.count

    // The strip is pinned to the scroll view's content (clip) view; fragment
    // frames are in the document (content) view's space. Convert by the current
    // scroll offset so a fragment at document-y maps to strip-y.
    let scrollOffsetY = scrollView.contentView.bounds.origin.y

    layoutManager.enumerateTextLayoutFragments(from: viewportRange.location, options: [.ensuresLayout]) { fragment in
      // Stop once we've walked past the viewport.
      if fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedDescending {
        return false
      }
      lineNumber += 1
      let frame = fragment.layoutFragmentFrame
      if let kind = self.status[lineNumber] {
        self.drawBar(kind: kind, atDocumentY: frame.origin.y, height: frame.height, scrollOffsetY: scrollOffsetY)
      }
      return true
    }
  }

  private func drawBar(
    kind: EditorGutterChangeKind, atDocumentY documentY: CGFloat, height: CGFloat, scrollOffsetY: CGFloat
  ) {
    let stripY = documentY - scrollOffsetY
    let color: NSColor
    switch kind {
    case .added: color = .systemGreen
    case .modified: color = .systemBlue
    case .removedAbove: color = .systemRed
    }

    switch kind {
    case .added, .modified:
      let rect = CGRect(x: 0, y: stripY, width: Self.stripWidth, height: max(1, height))
      color.setFill()
      rect.fill()
    case .removedAbove:
      // A deletion has no line of its own; draw a short wedge at the top boundary
      // of the surviving line so the user sees "something was removed here".
      let wedgeHeight: CGFloat = 4
      let rect = CGRect(x: 0, y: stripY - wedgeHeight / 2, width: Self.stripWidth, height: wedgeHeight)
      color.setFill()
      rect.fill()
    }
  }
}
