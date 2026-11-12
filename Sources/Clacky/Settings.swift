import Foundation

final class Settings {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.source: "rec:\(RecordedSwitch.default.id)",
            Key.volume: 0.6,
            Key.spatial: true,
            Key.releaseSounds: true,
            Key.steadyVolume: true,
        ])
    }

    private enum Key {
        static let enabled = "enabled"
        static let source = "soundSource"
        static let volume = "volume"
        static let spatial = "spatialAudio"
        static let releaseSounds = "releaseSounds"
        static let steadyVolume = "steadyVolume"
        static let volumeReferences = "volumeReferences"
    }

    var steadyVolume: Bool {
        get { defaults.bool(forKey: Key.steadyVolume) }
        set { defaults.set(newValue, forKey: Key.steadyVolume) }
    }

    /// Per output device (by UID), the Mac volume in dB that Steady volume holds Clacky's
    /// loudness to: Clacky sounds as it would at this volume, whatever the Mac is set to.
    var volumeReferences: [String: Float] {
        get {
            (defaults.dictionary(forKey: Key.volumeReferences) as? [String: NSNumber])?
                .mapValues(\.floatValue) ?? [:]
        }
        set { defaults.set(newValue, forKey: Key.volumeReferences) }
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var sourceID: String {
        get { defaults.string(forKey: Key.source) ?? "rec:\(RecordedSwitch.default.id)" }
        set { defaults.set(newValue, forKey: Key.source) }
    }

    var volume: Float {
        get { defaults.float(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    var spatial: Bool {
        get { defaults.bool(forKey: Key.spatial) }
        set { defaults.set(newValue, forKey: Key.spatial) }
    }

    var releaseSounds: Bool {
        get { defaults.bool(forKey: Key.releaseSounds) }
        set { defaults.set(newValue, forKey: Key.releaseSounds) }
    }
}
