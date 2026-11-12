import AppKit

let arguments = CommandLine.arguments

// Developer commands (no UI): render demo WAVs or the menu bar icon to disk.
if let i = arguments.firstIndex(of: "--render-demo"), i + 1 < arguments.count {
    exit(DevTools.renderDemo(to: URL(fileURLWithPath: arguments[i + 1])))
}
if let i = arguments.firstIndex(of: "--check-pack"), i + 1 < arguments.count {
    exit(DevTools.checkPack(at: URL(fileURLWithPath: arguments[i + 1])))
}
if let i = arguments.firstIndex(of: "--export-panel"), i + 1 < arguments.count {
    exit(DevTools.exportPanel(to: URL(fileURLWithPath: arguments[i + 1])))
}
if let i = arguments.firstIndex(of: "--export-icon"), i + 1 < arguments.count {
    exit(DevTools.exportMenuBarIcon(to: URL(fileURLWithPath: arguments[i + 1])))
}

// Only one Clacky at a time.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = AppModel()
let statusItem = StatusItemController(model: model)
model.start()
app.run()
