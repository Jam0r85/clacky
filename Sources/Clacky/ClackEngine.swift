import AudioToolbox
import AVFoundation
import ClackyCore
import CoreAudio
import CoreGraphics
import Foundation

/// Owns the audio graph and turns key events into placed voices.
///
/// Cost model: while you type, the audio thread mixes a handful of short voices.
/// Once you stop typing (`typingTimeout`) or leave the Mac (`awayTimeout`), the engine
/// pauses and the audio hardware is released, so an idle Clacky uses no audio CPU at all.
final class ClackEngine {
    /// How long the engine stays up after the last key. Long enough to ride out pauses for
    /// reading and thinking: restarting the output costs little on built-in speakers, but
    /// Bluetooth headphones drop the first few hundred ms while their link wakes, which
    /// swallowed the first keystrokes after every pause.
    static let typingTimeout: CFTimeInterval = 5 * 60
    /// Lets go sooner once nobody is at the Mac (no key, mouse or trackpad input), because
    /// a running output keeps coreaudiod holding off idle sleep.
    static let awayTimeout: CFTimeInterval = 2 * 60
    private static let anyInput = CGEventType(rawValue: ~0)! // kCGAnyInputEventType
    /// Every sound is decoded to this rate, and the mixer runs at it.
    static let sampleRate: Float = 48_000

    private let engine = AVAudioEngine()
    private let mixer: OpaquePointer
    private var sourceNode: AVAudioSourceNode!
    private var idleTimer: Timer?
    private var lastActivity: CFAbsoluteTime = 0
    private var startedAt: CFAbsoluteTime = 0
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?

    /// A running output asks for audio every few milliseconds. Going this long without a
    /// request means it's wedged (the device went away, coreaudiod restarted...).
    static let stallTimeout: CFTimeInterval = 2
    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    /// Built-in sources are small, so they're kept once made. Imported packs are freed
    /// when replaced, but only while the audio thread is idle (see `freeRetired`).
    private var cache: [String: SoundSource] = [:]
    private var retired: [SoundSource] = []
    private(set) var source: SoundSource?

    var spatial = true
    var releaseSounds = true
    var volume: Float = 0.6 { didSet { applyVolume() } }
    /// Extra gain that makes up for the Mac's own volume (1 = none). Can go above 1.
    var compensation: Float = 1 { didSet { applyVolume() } }

    init() {
        mixer = kc_mixer_create()
        kc_mixer_set_volume(mixer, volume)

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 2)!
        let m = mixer
        sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if !kc_mixer_render(m, frameCount, left, right) { isSilence.pointee = true }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        requestLowLatency()
        engine.prepare()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.rebuild() }

        // AVAudioEngine doesn't always post a configuration change when the output moves to
        // another device (headphones disconnecting while Clacky is playing, say). It follows
        // the new device but keeps buffer sizes worked out for the old one, and every render
        // then fails, silently, until the app quits. So rebuild on every default-output change.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            deviceListener = listener
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let deviceListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        }
        pendingRebuild?.cancel()
        engine.stop()
        kc_mixer_destroy(mixer)
    }

    private func applyVolume() { kc_mixer_set_volume(mixer, volume * compensation) }

    // MARK: - Sounds

    /// Selects a sound source by id: `rec:<switch>` or `pack:<folder>`.
    func select(sourceID: String) throws {
        if source?.id == sourceID { return }
        let new = try cache[sourceID] ?? Self.makeSource(id: sourceID)
        if !(new is PackSource) { cache[sourceID] = new }
        if let old = source, old is PackSource, old !== new {
            retired.append(old)
            if !engine.isRunning { freeRetired() }
        }
        source = new
    }

    static func makeSource(id: String) throws -> SoundSource {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw SoundPackError.noSounds }
        switch parts[0] {
        case "rec":
            guard let rec = RecordedSwitch.named(parts[1]), let dir = RecordedSwitch.directory else {
                throw SoundPackError.noSounds
            }
            return try RecordedSource(recording: rec, directory: dir)
        case "pack":
            return try PackSource(folder: PackLibrary.folder(named: parts[1]))
        default:
            throw SoundPackError.noSounds
        }
    }

    // MARK: - Playing

    func play(keyCode: UInt16, down: Bool) {
        guard var params = voice(for: keyCode, down: down) else { return }
        wake() // first: recovering a wedged output resets the mixer, which would drop this voice
        kc_mixer_trigger(mixer, &params)
    }

    /// A short left-to-right run across the keyboard, to audition a switch and the spatial spread.
    func preview() {
        let keys: [UInt16] = [50, 0, 3, 38, 37, 51] // ` A F J L Delete
        for (i, key) in keys.enumerated() {
            let t = Double(i) * 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.play(keyCode: key, down: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.075) { self.play(keyCode: key, down: false) }
        }
    }

    /// Everything the mixer needs for one keystroke, or nil if this key makes no sound.
    func voice(for keyCode: UInt16, down: Bool) -> kc_voice_params? {
        guard down || releaseSounds, let source, let sound = source.sound(for: keyCode, down: down) else { return nil }
        let key = KeyLayout.info(for: keyCode)

        var rate: Float = 1
        if source.randomPitch {
            // Each key keeps its own pitch (±2.5%), plus a tiny wobble per press.
            let keyOffset = (Float(KeyLayout.hash(keyCode) % 1000) / 1000 - 0.5) * 0.05
            rate = 1 + keyOffset + Float.random(in: -0.006...0.006)
        }
        let gain = Float.random(in: 0.92...1.05)
        let p = Self.placement(x: spatial ? key.x : 0.5)

        return kc_voice_params(
            samples: sound.samples, length: sound.length, rate: rate,
            gain_l: p.gainL * gain, gain_r: p.gainR * gain,
            delay_l: p.delayL, delay_r: p.delayR, lp_l: p.lpL, lp_r: p.lpR)
    }

    struct Placement { var gainL, gainR, delayL, delayR, lpL, lpR: Float }

    /// Binaural placement for a key at horizontal position x (0 = left, 1 = right).
    ///
    /// The keyboard is treated as an arc in front of you spanning ±55°. Each ear gets
    /// a level difference, an interaural time delay (Woodworth's formula) and a
    /// gentle low-pass on the far ear for head shadow. Cheap, and convincing on headphones.
    static func placement(x: Float) -> Placement {
        let pan = min(max(x * 2 - 1, -1), 1)
        let azimuth = pan * 55 * Float.pi / 180
        let s = sinf(azimuth) * 0.85
        let gainL = sqrtf(0.5 * (1 - s)), gainR = sqrtf(0.5 * (1 + s))

        let headRadius: Float = 0.0875, speedOfSound: Float = 343
        let itd = headRadius / speedOfSound * (abs(azimuth) + abs(sinf(azimuth))) * Self.sampleRate
        let shadow = 1 - 0.55 * abs(sinf(azimuth)) / sinf(55 * Float.pi / 180)

        if pan > 0 { // key on the right: left ear is the far ear
            return Placement(gainL: gainL, gainR: gainR, delayL: itd, delayR: 0, lpL: shadow, lpR: 1)
        } else {
            return Placement(gainL: gainL, gainR: gainR, delayL: 0, delayR: itd, lpL: 1, lpR: shadow)
        }
    }

    // MARK: - Engine lifecycle

    private func wake() {
        lastActivity = CFAbsoluteTimeGetCurrent()
        if engine.isRunning {
            guard isStalled else { return }
            NSLog("Clacky: the audio output stopped asking for sound; rebuilding it")
            rebuild()
        }
        do {
            try engine.start()
        } catch {
            NSLog("Clacky: audio engine failed to start: \(error.localizedDescription)")
            return
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.checkIdle() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// The engine says it's running, but the output hasn't asked for audio in a while.
    /// Queued clicks then never play, so the idle check below would wait on them forever
    /// and keep the audio hardware (and the Mac) awake for hours.
    private var isStalled: Bool {
        engine.isRunning
            && CFAbsoluteTimeGetCurrent() - startedAt > Self.stallTimeout
            && kc_mixer_seconds_since_render(mixer) > Self.stallTimeout
    }

    private func checkIdle() {
        if isStalled {
            NSLog("Clacky: the audio output stopped asking for sound; releasing it")
            rebuild()
            return
        }
        let sinceKey = CFAbsoluteTimeGetCurrent() - lastActivity
        let sinceInput = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
        guard sinceKey > Self.typingTimeout || sinceInput > Self.awayTimeout,
              kc_mixer_active_voices(mixer) == 0 else { return }
        suspend()
    }

    /// Releases the audio hardware. The next key press wakes it again.
    func suspend() {
        idleTimer?.invalidate()
        idleTimer = nil
        if engine.isRunning { engine.pause() }
        freeRetired()
    }

    /// Only safe while the engine isn't rendering: no voice can still point at old samples.
    private func freeRetired() {
        guard !retired.isEmpty else { return }
        kc_mixer_reset(mixer)
        retired.removeAll()
    }

    /// The default output changed (headphones, AirPods, display audio...). Waits a moment
    /// for the switch to settle, and coalesces the burst of changes a Bluetooth hand-off makes.
    private func outputDeviceChanged() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Stops the engine and rewires it to the current output's format, so buffer sizes are
    /// worked out afresh for that device. The next key press starts it again.
    private func rebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        idleTimer?.invalidate()
        idleTimer = nil
        engine.stop()
        kc_mixer_reset(mixer)
        retired.removeAll()
        engine.reset()
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        }
        requestLowLatency()
        engine.prepare()
    }

    /// Asks for a 256-frame I/O buffer (~5 ms) so clicks land with the key press.
    private func requestLowLatency() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 256
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }
}
