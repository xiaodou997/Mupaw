import AppKit
import Foundation

@main
final class RecordingFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var label: NSTextField?
    private var timer: Timer?
    private var tick = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = RecordingFixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }

        let size = NSSize(width: 900, height: 600)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Mupaw Recording Fixture"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.40, alpha: 1)
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        window.hidesOnDeactivate = false

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: "Mupaw Recording Fixture · 0000")
        label.font = .monospacedSystemFont(ofSize: 34, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = root.bounds.insetBy(dx: 40, dy: 40)
        label.autoresizingMask = [.width, .height]
        root.addSubview(label)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.label = label
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.advance()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func advance() {
        tick += 1
        label?.stringValue = String(format: "Mupaw Recording Fixture · %04d", tick)
        let phase = Double(tick % 120) / 120.0
        window?.backgroundColor = NSColor(
            calibratedHue: 0.56 + phase * 0.10,
            saturation: 0.72,
            brightness: 0.55 + phase * 0.25,
            alpha: 1
        )
    }
}
