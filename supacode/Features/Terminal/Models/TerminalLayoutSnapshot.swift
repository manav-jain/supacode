import Foundation
import SupacodeSettingsShared

struct TerminalLayoutSnapshot: Codable, Equatable, Sendable {
  let tabs: [TabSnapshot]
  let selectedTabIndex: Int

  /// Persisted tab kind. Stored as a String rawValue (not the in-memory
  /// `TerminalTabKind`) so a future kind doesn't break decode and an unknown
  /// value falls back to `.terminal`. Mirrors the on-disk forward-compat
  /// posture of `tintColor` / `agents`.
  enum TabKind: String, Codable, Equatable, Sendable {
    case terminal
    case editor
  }

  struct TabSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let title: String
    let customTitle: String?
    let icon: String?
    let tintColor: RepositoryColor?
    /// The split-tree layout for a terminal tab. Nil for an editor tab, which
    /// owns no surfaces. A terminal tab always carries one.
    let layout: LayoutNode?
    let focusedLeafIndex: Int
    /// Terminal vs editor. Absent on legacy snapshots → `.terminal`.
    let kind: TabKind
    /// The file open in an editor tab, as a filesystem path. Nil for an empty
    /// editor (no file) and for terminal tabs. Restored via `createEditorTab`.
    let editorFile: String?

    init(
      id: UUID?,
      title: String,
      customTitle: String?,
      icon: String?,
      tintColor: RepositoryColor?,
      layout: LayoutNode?,
      focusedLeafIndex: Int,
      kind: TabKind = .terminal,
      editorFile: String? = nil
    ) {
      self.id = id
      self.title = title
      self.customTitle = customTitle
      self.icon = icon
      self.tintColor = tintColor
      self.layout = layout
      self.focusedLeafIndex = focusedLeafIndex
      self.kind = kind
      self.editorFile = editorFile
    }

    private enum CodingKeys: String, CodingKey {
      case id, title, customTitle, icon, tintColor, layout, focusedLeafIndex, kind, editorFile
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(UUID.self, forKey: .id)
      title = try container.decode(String.self, forKey: .title)
      customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
      icon = try container.decodeIfPresent(String.self, forKey: .icon)
      // `try?` so a tint value the running build doesn't recognize (e.g. hex
      // from a newer build read by an older one) drops the field, not the tab.
      tintColor = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil
      // Editor tabs persist no layout; a terminal tab always carries one.
      // `decodeIfPresent` keeps legacy terminal-only snapshots decoding and
      // tolerates the new editor shape that omits `layout`.
      layout = try container.decodeIfPresent(LayoutNode.self, forKey: .layout)
      focusedLeafIndex = (try? container.decodeIfPresent(Int.self, forKey: .focusedLeafIndex)) ?? 0
      // Absent on legacy snapshots → `.terminal`. An unrecognized future value
      // also falls back to `.terminal` so a downgrade can't strand a tab.
      kind = (try? container.decodeIfPresent(TabKind.self, forKey: .kind)) ?? .terminal
      editorFile = try container.decodeIfPresent(String.self, forKey: .editorFile)
    }
  }

  indirect enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(SurfaceSnapshot)
    case split(SplitSnapshot)
  }

  struct SplitSnapshot: Codable, Equatable, Sendable {
    let direction: SplitDirection
    let ratio: Double
    let left: LayoutNode
    let right: LayoutNode
  }

  struct SurfaceSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let workingDirectory: String?
    /// Agent presence captured at quit, restored on next launch after an
    /// off-main liveness check. Nil on legacy layouts and fresh surfaces.
    let agents: [SurfaceAgentRecord]?

    init(id: UUID?, workingDirectory: String?, agents: [SurfaceAgentRecord]? = nil) {
      self.id = id
      self.workingDirectory = workingDirectory
      self.agents = agents
    }

    private enum CodingKeys: String, CodingKey {
      case id, workingDirectory, agents
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(UUID.self, forKey: .id)
      workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
      // `try?` so a future shape change drops the field, not the whole entry.
      agents = (try? container.decodeIfPresent([SurfaceAgentRecord].self, forKey: .agents)) ?? nil
    }
  }

  /// Persisted on background / quit; restore is best-effort and triple-defended
  /// (liveness, absence from layout, race-precedence). String fields are stored
  /// as rawValues so a future enum rename doesn't break decode.
  struct SurfaceAgentRecord: Codable, Equatable, Sendable {
    let agent: String
    let pids: [Int32]
    let activity: String
  }

}

nonisolated extension TerminalLayoutSnapshot.LayoutNode {
  /// The leftmost leaf in the subtree.
  var firstLeaf: TerminalLayoutSnapshot.SurfaceSnapshot {
    switch self {
    case .leaf(let surface):
      return surface
    case .split(let split):
      return split.left.firstLeaf
    }
  }

  /// The number of leaves in the subtree.
  var leafCount: Int {
    switch self {
    case .leaf:
      return 1
    case .split(let split):
      return split.left.leafCount + split.right.leafCount
    }
  }

  /// Surface UUIDs claimed by every leaf in this subtree. Used by the orphan
  /// reaper to know which zmx sessions are still "owned" by persisted layouts.
  var leafSurfaceIDs: [UUID] {
    switch self {
    case .leaf(let surface):
      return surface.id.map { [$0] } ?? []
    case .split(let split):
      return split.left.leafSurfaceIDs + split.right.leafSurfaceIDs
    }
  }
}

nonisolated extension TerminalLayoutSnapshot {
  /// Every surface UUID persisted across every tab in this layout. Drives the
  /// launch-time orphan-session reaper: any `supa-<uuid>` zmx hosts that isn't
  /// in this set across all worktrees is safe to kill. Editor tabs own no
  /// layout, so they contribute no surface IDs.
  var allSurfaceIDs: [UUID] {
    tabs.flatMap { $0.layout?.leafSurfaceIDs ?? [] }
  }

  /// Walk every leaf in every tab and emit `(surfaceID, [agents])` for any
  /// leaf with a non-empty `agents` array. Source of truth for the launch-time
  /// agent-presence restore now that records live in layout leaves instead of
  /// a parallel `agent-presence.json` file. Editor tabs own no layout / agents.
  func allAgentRecords() -> [(surfaceID: UUID, records: [SurfaceAgentRecord])] {
    tabs.flatMap { $0.layout?.leafAgents() ?? [] }
  }
}

nonisolated extension TerminalLayoutSnapshot.LayoutNode {
  fileprivate func leafAgents() -> [(surfaceID: UUID, records: [TerminalLayoutSnapshot.SurfaceAgentRecord])] {
    switch self {
    case .leaf(let surface):
      guard let id = surface.id, let agents = surface.agents, !agents.isEmpty else { return [] }
      return [(id, agents)]
    case .split(let split):
      return split.left.leafAgents() + split.right.leafAgents()
    }
  }
}
