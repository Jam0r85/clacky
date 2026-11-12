import AppKit
import Combine
import SwiftUI

/// The keycap in the menu bar and the panel that drops down from it.
///
/// Click: open or close the panel. ⌥-click: turn Clacky on or off without opening anything.
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// Built on first open, so SwiftUI costs nothing until the panel is used.
    private lazy var hostingView: PanelHostingView = {
        let view = PanelHostingView(rootView: PanelView(model: model))
        view.onSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.positionPanel() }
        }
        return view
    }()
    private lazy var panel = StatusPanel(content: hostingView)
    private var panelLoaded = false
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()
        model.dismissPanel = { [weak self] in self?.hidePanel(animated: false) }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        Publishers.CombineLatest3(model.$enabled, model.$listening, model.$sourceID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateButton() }
            .store(in: &cancellables)

        if ProcessInfo.processInfo.environment["CLACKY_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPanel() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = Icons.keycap(active: model.enabled && model.listening)
        if !model.enabled {
            button.toolTip = "Clacky is off — ⌥-click to turn on"
        } else if !model.listening {
            button.toolTip = "Clacky needs Input Monitoring access"
        } else {
            button.toolTip = "Clacky: \(model.currentTitle) — ⌥-click to turn off"
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            model.setEnabled(!model.enabled)
            return
        }
        panelLoaded && panel.isVisible ? hidePanel(animated: true) : showPanel()
    }

    // MARK: - Panel

    private func showPanel() {
        panelLoaded = true
        model.refresh()
        model.updater.panelVisibilityChanged(true)
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Recompute the shadow once the rounded content has actually drawn.
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.hidePanel(animated: true)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.panel.isKeyWindow == true else { return event } // Esc
            self?.hidePanel(animated: true)
            return nil
        }
    }

    private func hidePanel(animated: Bool) {
        guard panelLoaded, panel.isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
        statusItem.button?.highlight(false)
        model.updater.panelVisibilityChanged(false)
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    /// Keeps the panel's top edge just under the icon as its content grows or shrinks.
    private func positionPanel() {
        guard panelLoaded, let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hostingView.fittingSize
        var x = buttonRect.midX - size.width / 2
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let frame = NSRect(x: x, y: buttonRect.minY - size.height - 6, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}

/// Borderless floating panel with the menu material, like Control Center's drop-downs.
final class StatusPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // The behind-window blur is drawn by the window server for the whole window, so a
        // layer corner radius doesn't clip it (the corners show square). A mask image does,
        // and it also gives the window shadow the rounded shape.
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    static let cornerRadius: CGFloat = 14

    /// A stretchable rounded rectangle: only the corners keep their shape when resized.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Tells the controller when SwiftUI wants a different size (e.g. a permission banner appears).
final class PanelHostingView: NSHostingView<PanelView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}
