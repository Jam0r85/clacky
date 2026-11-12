import AudioToolbox
import AVFoundation
import ClackyCore
import CoreAudio
import Foundation

/// Owns the audio graph and turns key events into placed voices.
///
/// Cost model: while you type, the audio thread mixes a handful of short voices.
/// After `idleTimeout` seconds without a key, the engine pauses and the audio
/// hardware is released, so an idle Clacky uses no audio CPU at all.
final class ClackEngine {
    static let idleTimeout: CFTimeInterval = 20
    /// Every sound is decoded to this rate, and the mixer runs at it.
    static let sampleRate: Float = 48_000

    private let engine = AVAudioEngine()
    private let mixer: OpaquePointer
    private var sourceNode: AVAudioSourceNode!
    private var idleTimer: Timer?
    private var lastActivity: CFAbsoluteTime = 0
    private var configObserver: NSObjectProtocol?

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
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
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
        kc_mixer_trigger(mixer, &params)
        wake()
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
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Clacky: audio engine failed to start: \(error.localizedDescription)")
            return
        }
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkIdle() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        guard CFAbsoluteTimeGetCurrent() - lastActivity > Self.idleTimeout,
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

    private func handleConfigurationChange() {
        // The output device changed (headphones, AirPods, display audio...). The engine
        // has already stopped; rewire to the new hardware format and wait for the next key.
        idleTimer?.invalidate()
        idleTimer = nil
        kc_mixer_reset(mixer)
        retired.removeAll()
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
