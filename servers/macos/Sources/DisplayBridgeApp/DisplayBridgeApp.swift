import SwiftUI
import AppKit
import DisplayBridgeCore

@main
struct DisplayBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("DisplayBridge", systemImage: appDelegate.serverManager.isRunning ? "display" : "display.trianglebadge.exclamationmark") {
            MenuBarView()
                .environmentObject(appDelegate.serverManager)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let serverManager = ServerManager()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory: no Terminal window, no Dock icon — lives in menu bar only.
        // SPM executable targets don't produce .app bundles, so .regular
        // would cause macOS to open a Terminal window as the "host app".
        NSApplication.shared.setActivationPolicy(.accessory)
        showWindow()
    }

    func showWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ContentView()
            .environmentObject(serverManager)
            .frame(minWidth: 480, minHeight: 360)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "DisplayBridge"
        win.contentView = NSHostingView(rootView: contentView)
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.miniaturize(nil)
        return false
    }
}
