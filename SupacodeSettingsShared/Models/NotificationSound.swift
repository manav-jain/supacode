import Foundation

/// The tone played for an in-app notification when "Play notification sound"
/// is enabled. Every case maps to an original sound bundled in the app —
/// `.classic` is the long-standing `notification.wav`; the rest are
/// synthesized by `scripts/generate-notification-sounds.py` and live in
/// `supacode/Sounds/`.
///
/// Raw values are the persisted Codable representation, so don't rename a
/// case without a migration. New values from a future build decode to `nil`
/// at the call site and fall back to `.classic`.
public nonisolated enum NotificationSound: String, Codable, CaseIterable, Sendable, Identifiable {
  case classic
  case chime
  case chooChoo
  case inboundTrain
  case gong
  case standClear
  case ding

  public var id: String { rawValue }

  /// Human-readable name shown in the settings picker.
  public var label: String {
    switch self {
    case .classic: "Classic"
    case .chime: "Chime"
    case .chooChoo: "Choo Choo"
    case .inboundTrain: "Inbound Train"
    case .gong: "Gong"
    case .standClear: "Stand Clear"
    case .ding: "Ding"
    }
  }

  /// Bundle resource base name (no extension). `.classic` keeps the original
  /// top-level `notification.wav`; everything else lives under `Sounds/` but
  /// flattens into the app bundle's resources at build time.
  public var resourceName: String {
    switch self {
    case .classic: "notification"
    case .chime: "chime"
    case .chooChoo: "choo-choo"
    case .inboundTrain: "inbound-train"
    case .gong: "gong"
    case .standClear: "stand-clear"
    case .ding: "ding"
    }
  }

  public var fileExtension: String { "wav" }
}
