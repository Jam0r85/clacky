import AudioToolbox
import CoreAudio
import Foundation

/// Watches the volume and mute of the Mac's output device.
///
/// macOS applies volume and mute to the device, after every app's sound has been mixed
/// together, so no app can be heard through mute. What Clacky can do is turn itself up
/// when the Mac is turned down (within the room its clicks have before clipping) and
/// down when the Mac is turned up.
///
/// Listeners fire on the main queue only when something changes, so this costs nothing
/// while the volume sits still.
final class SystemVolume {
    struct State: Equatable {
        /// The output device, so a level remembered on one device isn't applied to another.
        var deviceUID: String
        /// The device's volume in dB on its own scale. Only differences matter.
        /// Nil when the device has no volume control (HDMI, many interfaces), so its level is
        /// fixed, or when the volume is at zero.
        var levelDB: Float?
        var muted: Bool
    }

    var onChange: ((State) -> Void)?
    private(set) var state: State?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var watched: [AudioObjectPropertyAddress] = []
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let output = kAudioDevicePropertyScopeOutput
    private static let main = kAudioObjectPropertyElementMain
    private static let defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        var address = Self.defaultOutput
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listener)
        update()
    }

    deinit {
        unwatchDevice()
        guard started else { return }
        var address = Self.defaultOutput
        AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, listener)
    }

    private func update() {
        let current = Self.read(Self.system, Self.defaultOutput, AudioObjectID(kAudioObjectUnknown))
            ?? AudioObjectID(kAudioObjectUnknown)
        if current != device {
            unwatchDevice()
            device = current
            watchDevice()
        }

        let new = device == kAudioObjectUnknown ? nil : Self.state(of: device)
        guard new != state else { return }
        state = new
        if let new { onChange?(new) }
    }

    // MARK: - Listening

    private func watchDevice() {
        guard device != kAudioObjectUnknown else { return }
        var candidates = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       mScope: Self.output, mElement: Self.main),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: Self.output, mElement: Self.main),
        ]
        // The virtual main volume is built from these, and not every device reports changes to it.
        for element: AudioObjectPropertyElement in [Self.main, 1, 2] {
            candidates.append(AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                         mScope: Self.output, mElement: element))
        }
        for var address in candidates where AudioObjectHasProperty(device, &address) {
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr {
                watched.append(address)
            }
        }
    }

    private func unwatchDevice() {
        for var address in watched {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        watched.removeAll()
    }

    // MARK: - Reading

    private static func state(of device: AudioObjectID) -> State {
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: main)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid)
        let uidString = uidStatus == noErr ? (uid?.takeRetainedValue() as String?) : nil

        let volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                mScope: output, mElement: main)
        let scalar: Float32? = read(device, volume, 0)
        let muteFlag: UInt32? = read(device, AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: output, mElement: main), 0)

        return State(deviceUID: uidString ?? "device-\(device)",
                     levelDB: scalar.flatMap { $0 > 0 ? decibels(device: device, scalar: $0) : nil },
                     muted: muteFlag == 1 || scalar == 0)
    }

    /// The device's own scalar-to-dB curve. Built-in speakers, for example, are a straight
    /// line from -63.5 dB to 0 dB, about 4 dB per volume-key press.
    private static func decibels(device: AudioObjectID, scalar: Float32) -> Float {
        for element: AudioObjectPropertyElement in [main, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
                                                     mScope: output, mElement: element)
            guard AudioObjectHasProperty(device, &address),
                  let db: Float32 = read(device, address, scalar), db.isFinite else { continue }
            return db
        }
        // No curve published: assume a common audio taper.
        return 40 * log10f(max(scalar, 0.001))
    }

    /// Reads a plain value. `initial` is also the input for translation properties.
    private static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }
}
