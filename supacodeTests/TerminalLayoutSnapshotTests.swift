import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct TerminalLayoutSnapshotTests {
  @Test func decodeLegacyTintColorPredefinedString() throws {
    // Old layout snapshots (pre-RepositoryColor cascade) wrote `tintColor`
    // as `TerminalTabTintColor` raw values. The new `RepositoryColor.parse`
    // accepts the same names, so existing files migrate transparently.
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": "teal",
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.tintColor == .teal)
  }

  @Test func decodeLayoutTintColorCustomHex() throws {
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": "#A1B2C3",
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.tintColor == .custom("#A1B2C3"))
  }

  @Test func codableRoundTrip() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "main 1",
          customTitle: nil,
          icon: "terminal",
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.7,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/Users/test/project")),
              right: .split(
                TerminalLayoutSnapshot.SplitSnapshot(
                  direction: .vertical,
                  ratio: 0.4,
                  left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/tmp")),
                  right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil))
                )
              )
            )
          ),
          focusedLeafIndex: 1
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "main 2",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/Users/test")),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded == snapshot)
  }

  @Test func firstLeafReturnsLeftmost() {
    let node: TerminalLayoutSnapshot.LayoutNode = .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/first")),
        right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/second"))
      )
    )
    #expect(node.firstLeaf.workingDirectory == "/first")
  }

  @Test func leafCountCountsAllLeaves() {
    let node: TerminalLayoutSnapshot.LayoutNode = .split(
      TerminalLayoutSnapshot.SplitSnapshot(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
        right: .split(
          TerminalLayoutSnapshot.SplitSnapshot(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
            right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil))
          )
        )
      )
    )
    #expect(node.leafCount == 3)
  }

  @Test func customTitleRoundTripsInSnapshot() throws {
    let tabSnapshot = TerminalLayoutSnapshot.TabSnapshot(
      id: UUID(),
      title: "supacode 1",
      customTitle: "my-tab",
      icon: nil,
      tintColor: nil,
      layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: UUID(), workingDirectory: nil)),
      focusedLeafIndex: 0
    )
    let snapshot = TerminalLayoutSnapshot(tabs: [tabSnapshot], selectedTabIndex: 0)
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.first?.customTitle == "my-tab")
  }

  @Test func missingCustomTitleDecodesAsNil() throws {
    let leaf = #"{"leaf":{"_0":{"workingDirectory":null}}}"#
    let tab = #"{"title":"tab 1","layout":\#(leaf),"focusedLeafIndex":0}"#
    let json = #"{"tabs":[\#(tab)],"selectedTabIndex":0}"#
    let snapshot = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    #expect(snapshot.tabs.first?.customTitle == nil)
  }

  @Test func singleLeafLayout() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/home")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded.tabs.count == 1)
    #expect(decoded.tabs[0].layout?.firstLeaf.workingDirectory == "/home")
    #expect(decoded.tabs[0].layout?.leafCount == 1)
  }

  @Test func allSurfaceIDsCollectsLeavesAcrossTabsAndSplits() {
    let leftSurface = UUID()
    let rightSurface = UUID()
    let secondTabSurface = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: leftSurface, workingDirectory: nil)),
              right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: rightSurface, workingDirectory: nil))
            )
          ),
          focusedLeafIndex: 0
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab2",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: secondTabSurface, workingDirectory: nil)),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )

    #expect(Set(snapshot.allSurfaceIDs) == [leftSurface, rightSurface, secondTabSurface])
  }

  @Test func surfaceSnapshotRoundTripsAgentRecords() throws {
    // Co-locating agent presence with the layout means a Codable round-trip
    // through the on-disk JSON format must preserve every field bit-for-bit;
    // otherwise the relaunch restore would silently miss agents.
    let surfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: surfaceID,
              workingDirectory: "/repo",
              agents: [
                TerminalLayoutSnapshot.SurfaceAgentRecord(
                  agent: "claude",
                  pids: [12345, 67890],
                  activity: "busy"
                ),
                TerminalLayoutSnapshot.SurfaceAgentRecord(
                  agent: "codex",
                  pids: [42],
                  activity: "idle"
                ),
              ]
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)

    #expect(decoded == snapshot)
    let leaf = try #require(decoded.tabs[0].layout).firstLeaf
    #expect(leaf.agents?.count == 2)
    #expect(leaf.agents?[0].pids == [12345, 67890])
    #expect(leaf.agents?[1].activity == "idle")
  }

  @Test func surfaceSnapshotDecodesWithoutAgentsForBackCompat() throws {
    // Older builds wrote layouts without the `agents` field. Newer builds
    // must decode those without throwing. The synthesized Codable for
    // `LayoutNode` wraps associated values in `_0`.
    let json = """
      {
        "tabs": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "tab",
            "layout": {
              "leaf": { "_0": { "id": "00000000-0000-0000-0000-000000000002" } }
            },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    let leaf = try #require(decoded.tabs[0].layout).firstLeaf
    #expect(leaf.agents == nil)
    #expect(leaf.id == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
  }

  @Test func surfaceSnapshotToleratesMalformedAgentsField() throws {
    // A future build with a richer SurfaceAgentRecord shape might serialize a
    // shape this build can't parse. Dropping the field rather than failing
    // the whole layout keeps downgrade scenarios survivable.
    let json = """
      {
        "tabs": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "tab",
            "layout": {
              "leaf": {
                "_0": {
                  "id": "00000000-0000-0000-0000-000000000002",
                  "agents": "not-an-array"
                }
              }
            },
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """
    let decoded = try JSONDecoder().decode(
      TerminalLayoutSnapshot.self,
      from: Data(json.utf8)
    )
    let leaf = try #require(decoded.tabs[0].layout).firstLeaf
    #expect(leaf.agents == nil)
  }

  @Test func allAgentRecordsCollectsAcrossTabsAndSplits() {
    let surfaceA = UUID()
    let surfaceB = UUID()
    let layout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot(
                  id: surfaceA,
                  workingDirectory: nil,
                  agents: [
                    TerminalLayoutSnapshot.SurfaceAgentRecord(
                      agent: "claude", pids: [1], activity: "idle"
                    )
                  ]
                )
              ),
              right: .leaf(
                TerminalLayoutSnapshot.SurfaceSnapshot(id: surfaceB, workingDirectory: nil, agents: nil)
              )
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    let records = layout.allAgentRecords()
    #expect(records.count == 1)
    #expect(records[0].surfaceID == surfaceA)
  }

  @Test func allSurfaceIDsSkipsLeavesWithoutIDs() {
    // Snapshots from older builds can carry leaves with `id == nil`; those
    // can't be reaped against (no UUID → no `supa-<uuid>` to match), so they
    // shouldn't appear in the known-set the reaper consults.
    let real = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
              right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: real, workingDirectory: nil))
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    #expect(snapshot.allSurfaceIDs == [real])
  }

  // MARK: - Editor tabs.

  @Test func editorTabRoundTripsKindAndFileAndOrderAndSelection() throws {
    // A worktree with a terminal tab + two editor tabs must round-trip the
    // editor file paths, the tab order, and the selected index.
    let terminalSurface = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "term 1",
          customTitle: nil,
          icon: "terminal",
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: terminalSurface, workingDirectory: "/repo")),
          focusedLeafIndex: 0
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "a.swift",
          customTitle: nil,
          icon: "doc.text",
          tintColor: nil,
          layout: nil,
          focusedLeafIndex: 0,
          kind: .editor,
          editorFile: "/repo/a.swift"
        ),
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "b.swift",
          customTitle: "renamed",
          icon: "doc.text",
          tintColor: nil,
          layout: nil,
          focusedLeafIndex: 0,
          kind: .editor,
          editorFile: "/repo/b.swift"
        ),
      ],
      selectedTabIndex: 2
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)

    #expect(decoded == snapshot)
    #expect(decoded.selectedTabIndex == 2)
    #expect(decoded.tabs.map(\.kind) == [.terminal, .editor, .editor])
    #expect(decoded.tabs.map(\.editorFile) == [nil, "/repo/a.swift", "/repo/b.swift"])
    #expect(decoded.tabs[1].layout == nil)
    #expect(decoded.tabs[2].customTitle == "renamed")
    // Editor tabs own no surfaces, so only the terminal tab contributes a surface ID.
    #expect(decoded.allSurfaceIDs == [terminalSurface])
  }

  @Test func legacySnapshotWithoutKindDecodesAsTerminal() throws {
    // Snapshots written before editor tabs existed have no `kind` / `editorFile`
    // field; those must decode as terminal tabs without throwing.
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": null,
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": "/home"}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.first?.kind == .terminal)
    #expect(decoded.tabs.first?.editorFile == nil)
    #expect(decoded.tabs.first?.layout?.firstLeaf.workingDirectory == "/home")
  }

  @Test func unknownKindRawValueDecodesAsTerminal() throws {
    // A future kind this build doesn't recognize must not strand the tab; it
    // falls back to `.terminal` (the `try?` on the kind decode).
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "kind": "diff-viewer",
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": "/home"}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.first?.kind == .terminal)
  }

  @Test func editorTabDecodesWithoutLayoutField() throws {
    // An editor tab persists no `layout`. Decoding one with only `kind` /
    // `editorFile` must succeed with a nil layout.
    let json = #"""
      {
        "tabs": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "a.swift",
            "kind": "editor",
            "editorFile": "/repo/a.swift",
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(decoded.tabs.first?.kind == .editor)
    #expect(decoded.tabs.first?.layout == nil)
    #expect(decoded.tabs.first?.editorFile == "/repo/a.swift")
  }
}
