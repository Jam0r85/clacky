import AppKit

enum Icons {
    /// Menu bar keycap seen from above: the skirt, the smaller dished top (set back
    /// toward the top edge, like a real sculpted keycap) and the four corner bevels.
    /// Filled when Clacky is listening, outlined when it's off or waiting for permission.
    static func keycap(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let outerRect = NSRect(x: 1.6, y: 1.6, width: 14.8, height: 14.8)
            let topRect = NSRect(x: 5.0, y: 6.0, width: 8.0, height: 7.6)
            let corners: [(NSPoint, NSPoint)] = [
                (NSPoint(x: topRect.minX + 0.6, y: topRect.minY + 0.6), NSPoint(x: outerRect.minX + 1.4, y: outerRect.minY + 1.4)),
                (NSPoint(x: topRect.maxX - 0.6, y: topRect.minY + 0.6), NSPoint(x: outerRect.maxX - 1.4, y: outerRect.minY + 1.4)),
                (NSPoint(x: topRect.minX + 0.6, y: topRect.maxY - 0.6), NSPoint(x: outerRect.minX + 1.4, y: outerRect.maxY - 1.4)),
                (NSPoint(x: topRect.maxX - 0.6, y: topRect.maxY - 0.6), NSPoint(x: outerRect.maxX - 1.4, y: outerRect.maxY - 1.4)),
            ]
            let bevels = NSBezierPath()
            for (a, b) in corners {
                bevels.move(to: a)
                bevels.line(to: b)
            }

            if active {
                NSBezierPath(roundedRect: outerRect, xRadius: 3.8, yRadius: 3.8).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let top = NSBezierPath(roundedRect: topRect, xRadius: 2, yRadius: 2)
                top.lineWidth = 1.2
                top.stroke()
                bevels.lineWidth = 1.0
                bevels.stroke()
            } else {
                let outer = NSBezierPath(roundedRect: outerRect.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.3, yRadius: 3.3)
                outer.lineWidth = 1.2
                outer.stroke()
                let top = NSBezierPath(roundedRect: topRect, xRadius: 1.8, yRadius: 1.8)
                top.lineWidth = 1.1
                top.stroke()
                bevels.lineWidth = 0.9
                bevels.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Clacky"
        return image
    }
}
