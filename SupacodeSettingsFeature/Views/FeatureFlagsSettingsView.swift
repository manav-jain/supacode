import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Settings pane that toggles in-development feature flags. Each toggle is backed
/// directly by `@Shared(.appStorage(flag.storageKey))` — the same store
/// `FeatureFlag.isEnabled` reads — so a flip takes effect immediately without
/// routing through `GlobalSettings`.
public struct FeatureFlagsSettingsView: View {
  public init() {}

  public var body: some View {
    Form {
      Section {
        ForEach(FeatureFlag.allCases, id: \.self) { flag in
          FeatureFlagToggle(flag: flag)
        }
      } footer: {
        Text("Experimental, in-development features. Everything here is off by default and may change or be removed.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Feature Flags")
  }
}

private struct FeatureFlagToggle: View {
  let flag: FeatureFlag
  @Shared var isEnabled: Bool

  init(flag: FeatureFlag) {
    self.flag = flag
    _isEnabled = Shared(wrappedValue: false, .appStorage(flag.storageKey))
  }

  var body: some View {
    Toggle(
      isOn: Binding(
        get: { isEnabled },
        set: { newValue in $isEnabled.withLock { $0 = newValue } }
      )
    ) {
      Text(flag.title)
      Text(flag.subtitle)
    }
    .help(flag.subtitle)
  }
}
