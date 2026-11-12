import AppKit
import Combine
import ServiceManagement

/// App state and actions, shared by the menu bar icon and the panel.
final class AppModel: ObservableObject {
    let engine = ClackEngine()
    let updater: Updater
    private let settings = Settings()
    private let monitor = KeyMonitor()
    private let systemVolume = SystemVolume()
    private var permissionTimer: Timer?

    @Published private(set) var enabled: Bool
    @Published private(set) var listening = false
    /// Permission was granted but the tap still couldn't be created (macOS sometimes wants a relaunch).
    @Published private(set) var needsRelaunch = false
    @Published private(set) var sourceID: String
    @Published private(set) var packs: [PackLibrary.Entry] = []
    @Published private(set) var launchAtLogin = false
    /// The Mac's output is muted or at zero. macOS silences every app then, Clacky included.
    @Published private(set) var macMuted = false

    /// Holds Clacky's loudness when the Mac's volume changes.
    @Published var steadyVolume: Bool {
        didSet {
            settings.steadyVolume = steadyVolume
            // Start from how it sounds right now, so turning it on never jumps.
            if steadyVolume, steadyVolume != oldValue { rememberVolumeReference() }
            applySystemVolume()
        }
    }

    @Published var volume: Float {
        didSet {
            settings.volume = volume
            engine.volume = Self.gain(forSlider: volume)
        }
    }

    @Published var spatial: Bool {
        didSet {
            settings.spatial = spatial
            engine.spatial = spatial
            if spatial != oldValue { engine.preview() }
        }
    }

    @Published var releaseSounds: Bool {
        didSet {
            settings.releaseSounds = releaseSounds
            engine.releaseSounds = releaseSounds
        }
    }

    /// Set by the status item so modal windows (open panel, alerts, About) can close the panel first.
    var dismissPanel: (() -> Void)?

    private static let inputMonitoringURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    init(checksForUpdates: Bool = true) {
        updater = Updater(startChecking: checksForUpdates)
        enabled = settings.enabled
        sourceID = settings.sourceID
        volume = settings.volume
        spatial = settings.spatial
        releaseSounds = settings.releaseSounds
        steadyVolume = settings.steadyVolume
        engine.volume = Self.gain(forSlider: volume)
        engine.spatial = spatial
        engine.releaseSounds = releaseSounds
    }

    func start() {
        if (try? engine.select(sourceID: sourceID)) == nil {
            sourceID = "rec:\(RecordedSwitch.default.id)"
            settings.sourceID = sourceID
            try? engine.select(sourceID: sourceID)
        }
        systemVolume.onChange = { [weak self] _ in self?.systemVolumeChanged() }
        systemVolume.start()
        monitor.onKey = { [weak self] code, down in self?.engine.play(keyCode: code, down: down) }
        if enabled { startListening(prompt: true) }
        refresh()
    }

    /// Re-reads things that can change outside the app. Called whenever the panel opens.
    func refresh() {
        packs = PackLibrary.installed()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        listening = enabled && monitor.isRunning
    }

    /// For rendering the panel offscreen as if Clacky were listening.
    func markListeningForPreview() { listening = true }
    func markMacMutedForPreview() { macMuted = true }

    // MARK: - Mac volume

    /// Most Clacky will boost itself to make up for a turned-down Mac. Beyond this it just
    /// gets quieter: there's only so much room before the clicks would distort.
    static let maxBoostDB: Float = 18

    /// Digital gain that keeps Clacky sounding as it would at `referenceDB` while the Mac is
    /// at `currentDB`. Turning the Mac up is fully made up for; turning it down only up to
    /// `maxBoostDB`, and the mixer's limiter catches any peaks that would clip.
    static func compensation(referenceDB: Float, currentDB: Float) -> Float {
        let db = min(max(referenceDB - currentDB, -60), maxBoostDB)
        return powf(10, db / 20)
    }

    private func systemVolumeChanged() {
        guard let state = systemVolume.state else { return }
        macMuted = state.muted
        // First time on this device (new headphones...): hold it to how it sounds now.
        if settings.volumeReferences[state.deviceUID] == nil { rememberVolumeReference() }
        applySystemVolume()
    }

    private func rememberVolumeReference() {
        guard let state = systemVolume.state, let db = state.levelDB else { return }
        settings.volumeReferences[state.deviceUID] = db
    }

    private func applySystemVolume() {
        guard steadyVolume, let state = systemVolume.state, let current = state.levelDB,
              let reference = settings.volumeReferences[state.deviceUID] else {
            engine.compensation = 1
            return
        }
        engine.compensation = Self.compensation(referenceDB: reference, currentDB: current)
    }

    // MARK: - What's playing

    var needsPermission: Bool { enabled && !listening }

    var currentTitle: String {
        if let rec = currentRecording { return rec.name }
        if let pack = packs.first(where: { $0.sourceID == sourceID }) { return pack.name }
        return engine.source?.displayName ?? "—"
    }

    var currentKind: String? {
        if let rec = currentRecording { return rec.kind }
        return sourceID.hasPrefix("pack:") ? "Sound pack" : nil
    }

    private var currentRecording: RecordedSwitch? {
        sourceID.hasPrefix("rec:") ? RecordedSwitch.named(String(sourceID.dropFirst(4))) : nil
    }

    func select(_ id: String) {
        do {
            try engine.select(sourceID: id)
            sourceID = id
            settings.sourceID = id
            engine.preview()
        } catch {
            showError("Couldn't load that sound", error)
        }
    }

    func playTestClick() {
        engine.play(keyCode: 3, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.engine.play(keyCode: 3, down: false) }
    }

    // MARK: - On / off and permission

    func setEnabled(_ on: Bool) {
        enabled = on
        settings.enabled = on
        if on {
            startListening(prompt: true)
        } else {
            stopPermissionPolling()
            monitor.stop()
            engine.suspend()
            listening = false
        }
    }

    private func startListening(prompt: Bool) {
        if KeyMonitor.hasPermission {
            needsRelaunch = !monitor.start()
            if !needsRelaunch { stopPermissionPolling() }
        } else {
            if prompt { KeyMonitor.requestPermission() }
            startPermissionPolling()
        }
        listening = enabled && monitor.isRunning
    }

    /// Cheap 2-second check that only runs while waiting for the user to grant access.
    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, KeyMonitor.hasPermission else { return }
            self.stopPermissionPolling()
            self.startListening(prompt: false)
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func openInputMonitoring() {
        KeyMonitor.requestPermission()
        NSWorkspace.shared.open(Self.inputMonitoringURL)
        startPermissionPolling()
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Sound packs

    func importPack() {
        dismissPanel?()
        let panel = NSOpenPanel()
        panel.title = "Import a Mechvibes Sound Pack"
        panel.message = "Choose a pack's .zip file, or the folder that contains its config.json."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entry = try PackLibrary.install(from: url)
            packs = PackLibrary.installed()
            select(entry.sourceID)
        } catch {
            showError("Couldn't import that sound pack", error)
        }
    }

    func removePack(_ entry: PackLibrary.Entry) {
        if sourceID == entry.sourceID { select("rec:\(RecordedSwitch.default.id)") }
        PackLibrary.remove(entry)
        packs = PackLibrary.installed()
    }

    func showPacksFolder() {
        dismissPanel?()
        try? FileManager.default.createDirectory(at: PackLibrary.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PackLibrary.root)
    }

    func findPacks() {
        dismissPanel?()
        NSWorkspace.shared.open(URL(string: "https://mechvibes.com/sound-packs")!)
    }

    // MARK: - App

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try service.unregister()
            }
        } catch {
            showError("Couldn't change Launch at Login", error)
        }
        launchAtLogin = service.status == .enabled
    }

    func showAbout() {
        dismissPanel?()
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Mechanical keyboard sounds for your Mac.\n\n" +
                "Switch recordings from kbsim by Thomas Lai (MIT).\n" +
                "Clacky only uses which key you pressed to pick a sound; it never records what you type. " +
                "Its only network request is the update check to GitHub.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func openGitHub() {
        dismissPanel?()
        NSWorkspace.shared.open(URL(string: "https://github.com/Jam0r85/clacky")!)
    }

    func quit() { NSApp.terminate(nil) }

    /// Perceptual volume curve for the slider.
    private static func gain(forSlider value: Float) -> Float { value * value }

    private func showError(_ message: String, _ error: Error) {
        dismissPanel?()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
