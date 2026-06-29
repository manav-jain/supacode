import AppKit
import ComposableArchitecture
import Foundation

/// Loads and plays the bundled notification tones. Lives in
/// `SupacodeSettingsShared` (next to `SystemNotificationClient`) so both the
/// app's notification delivery path and the Settings preview can reach it —
/// resources resolve from `Bundle.main` either way.
@MainActor
private final class NotificationSoundPlayer {
  static let shared = NotificationSoundPlayer()

  /// `NSSound` is cheap to keep around and decoding on every play would add
  /// latency, so loaded sounds are cached by case.
  private var cache: [NotificationSound: NSSound] = [:]
  /// Points into `cache`, so a weak reference is enough to stop the
  /// currently-playing tone when the user auditions another one.
  private weak var current: NSSound?

  func play(_ sound: NotificationSound) {
    let nsSound: NSSound
    if let cached = cache[sound] {
      nsSound = cached
    } else if let url = Bundle.main.url(forResource: sound.resourceName, withExtension: sound.fileExtension),
      let loaded = NSSound(contentsOf: url, byReference: true)
    {
      cache[sound] = loaded
      nsSound = loaded
    } else {
      return
    }
    // Stop the previous (and any in-flight repeat of this) tone so rapid
    // preview taps replace rather than overlap.
    current?.stop()
    nsSound.stop()
    nsSound.play()
    current = nsSound
  }
}

public nonisolated struct NotificationSoundClient: Sendable {
  public var play: @MainActor @Sendable (NotificationSound) -> Void

  public init(play: @escaping @MainActor @Sendable (NotificationSound) -> Void) {
    self.play = play
  }
}

extension NotificationSoundClient: DependencyKey {
  public static let liveValue = NotificationSoundClient(
    play: { sound in NotificationSoundPlayer.shared.play(sound) }
  )

  public static let testValue = NotificationSoundClient(
    play: { _ in }
  )
}

extension DependencyValues {
  public var notificationSoundClient: NotificationSoundClient {
    get { self[NotificationSoundClient.self] }
    set { self[NotificationSoundClient.self] = newValue }
  }
}
