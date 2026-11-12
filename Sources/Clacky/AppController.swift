import AppKit
import ServiceManagement

final class AppController: NSObject, NSMenuDelegate {
    private let settings = Settings()
    private let engine = ClackEngine()
    private let monitor = KeyMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var permissionTimer: Timer?
    /// Permission was granted but the tap still couldn't be created (macOS sometimes wants a relaunch).
    private var needsRelaunch = false

    private static let inputMonitoringURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    func start() {
        engine.volume = Self.gain(forSlider: settings.volume)
        engine.spatial = settings.spatial
        engine.releaseSounds = settings.releaseSounds
        if (try? engine.select(sourceID: settings.sourceID)) == nil {
            settings.sourceID = "rec:\(RecordedSwitch.default.id)"
            try? engine.select(sourceID: settings.sourceID)
        }

        monitor.onKey = { [weak self] code, down in self?.engine.play(keyCode: code, down: down) }

        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if settings.enabled { startListening(prompt: true) }
        updateStatusItem()
    }

    // MARK: - On / off

    private var isListening: Bool { settings.enabled && monitor.isRunning }

    private func setEnabled(_ on: Bool) {
        settings.enabled = on
        if on {
            startListening(prompt: true)
        } else {
            stopPermissionPolling()
            monitor.stop()
            engine.suspend()
        }
        updateStatusItem()
    }

    private func startListening(prompt: Bool) {
        if KeyMonitor.hasPermission {
            if monitor.start() {
                needsRelaunch = false
                stopPermissionPolling()
            } else {
                needsRelaunch = true
            }
        } else {
            if prompt { KeyMonitor.requestPermission() }
            startPermissionPolling()
        }
        updateStatusItem()
    }

    /// Cheap 2-second check that only runs while we're waiting for the user to grant access.
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

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Icons.keycap(active: isListening)
        if !settings.enabled {
            button.toolTip = "Clacky is off — ⌥-click to turn on"
        } else if !isListening {
            button.toolTip = "Clacky needs Input Monitoring access"
        } else {
            button.toolTip = "Clacky: \(engine.source?.displayName ?? "") — ⌥-click to turn off"
        }
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            setEnabled(!settings.enabled)
            return
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem()
        let state = !settings.enabled ? "Off" : (isListening ? "On" : "Needs permission")
        header.attributedTitle = Self.title("Clacky", detail: state, bold: true)
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(item("Enabled", #selector(toggleEnabled), on: settings.enabled))

        if settings.enabled && !isListening {
            if needsRelaunch {
                menu.addItem(item("Relaunch Clacky to Finish Setup", #selector(relaunch)))
            } else {
                menu.addItem(item("Allow Input Monitoring…", #selector(openInputMonitoring)))
                let hint = NSMenuItem()
                hint.attributedTitle = Self.hint("Clacky needs this to hear key presses.\nIt never records what you type.")
                hint.isEnabled = false
                menu.addItem(hint)
            }
        }

        menu.addItem(.separator())
        menu.addItem(Self.sectionHeader("Switches"))
        for entry in RecordedSwitch.menuOrder {
            guard let rec = entry else { continue }
            menu.addItem(sourceItem(id: "rec:\(rec.id)", name: rec.name, detail: rec.kind))
        }

        let packs = NSMenu()
        let installed = PackLibrary.installed()
        for pack in installed {
            packs.addItem(sourceItem(id: pack.sourceID, name: pack.name, detail: nil))
        }
        if !installed.isEmpty { packs.addItem(.separator()) }
        packs.addItem(item("Import Sound Pack…", #selector(importPack)))
        packs.addItem(item("Show Packs Folder", #selector(showPacksFolder)))
        packs.addItem(item("Find Packs Online…", #selector(findPacks)))
        let packsItem = NSMenuItem(title: "Sound Packs", action: nil, keyEquivalent: "")
        packsItem.submenu = packs
        packsItem.state = settings.sourceID.hasPrefix("pack:") ? .on : .off
        menu.addItem(packsItem)

        menu.addItem(.separator())
        menu.addItem(volumeItem())
        let spatial = item("Spatial Audio", #selector(toggleSpatial), on: settings.spatial)
        spatial.toolTip = "Places each key where it sits on the keyboard. Best with headphones."
        menu.addItem(spatial)
        menu.addItem(item("Key Release Sounds", #selector(toggleRelease), on: settings.releaseSounds))

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item("About Clacky", #selector(showAbout)))
        let quit = item("Quit Clacky", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled() { setEnabled(!settings.enabled) }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try engine.select(sourceID: id)
            settings.sourceID = id
            engine.preview()
            updateStatusItem()
        } catch {
            showError("Couldn't load “\(sender.title)”", error)
        }
    }

    @objc private func volumeChanged(_ slider: NSSlider) {
        settings.volume = Float(slider.doubleValue)
        engine.volume = Self.gain(forSlider: settings.volume)
        if NSApp.currentEvent?.type == .leftMouseUp {
            engine.play(keyCode: 3, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.engine.play(keyCode: 3, down: false) }
        }
    }

    @objc private func toggleSpatial() {
        settings.spatial.toggle()
        engine.spatial = settings.spatial
        engine.preview()
    }

    @objc private func toggleRelease() {
        settings.releaseSounds.toggle()
        engine.releaseSounds = settings.releaseSounds
    }

    @objc private func importPack() {
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
            try engine.select(sourceID: entry.sourceID)
            settings.sourceID = entry.sourceID
            engine.preview()
            updateStatusItem()
        } catch {
            showError("Couldn't import that sound pack", error)
        }
    }

    @objc private func showPacksFolder() {
        try? FileManager.default.createDirectory(at: PackLibrary.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(PackLibrary.root)
    }

    @objc private func findPacks() {
        NSWorkspace.shared.open(URL(string: "https://mechvibes.com/sound-packs")!)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showError("Couldn't change Launch at Login", error)
        }
    }

    @objc private func openInputMonitoring() {
        KeyMonitor.requestPermission()
        NSWorkspace.shared.open(Self.inputMonitoringURL)
        startPermissionPolling()
    }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Mechanical keyboard sounds for your Mac.\n\n" +
                "Switch recordings from kbsim by Thomas Lai (MIT).\n" +
                "Clacky only uses which key you pressed to pick a sound; it never records what you type.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    /// Perceptual volume curve for the slider.
    private static func gain(forSlider value: Float) -> Float { value * value }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    private func sourceItem(id: String, name: String, detail: String?) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: #selector(selectSource(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        if let detail { item.attributedTitle = Self.title(name, detail: detail) }
        item.state = settings.sourceID == id ? .on : .off
        return item
    }

    private func volumeItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Quieter")!)
        low.frame = NSRect(x: 20, y: 6, width: 16, height: 16)
        low.contentTintColor = .secondaryLabelColor
        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Louder")!)
        high.frame = NSRect(x: 226, y: 6, width: 20, height: 16)
        high.contentTintColor = .secondaryLabelColor
        let slider = NSSlider(value: Double(settings.volume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 42, y: 4, width: 178, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        view.addSubview(low)
        view.addSubview(slider)
        view.addSubview(high)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private static func title(_ name: String, detail: String, bold: Bool = false) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let s = NSMutableAttributedString(string: name, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.menuFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
        ])
        s.append(NSAttributedString(string: "  \(detail)", attributes: [
            .font: NSFont.menuFont(ofSize: size - 2),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return s
    }

    private static func hint(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func showError(_ message: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
