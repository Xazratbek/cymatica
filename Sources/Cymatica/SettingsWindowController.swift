import AppKit
import SwiftUI

/// Things the settings panes can ask the running app to do or report.
struct SettingsActions {
    var showNow: () -> Void = {}
    var rescatter: () -> Void = {}
    /// One-line description of where the audio comes from, or what went wrong.
    var audioStatus: () -> String = { "" }
}

/// Shows and hides the Dock icon while a regular window is open; the app otherwise
/// lives only in the menu bar.
@MainActor
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}

/// Settings window built in AppKit with `.fullSizeContentView`, which macOS 26+ needs
/// to draw the Liquid Glass chrome; a SwiftUI `Window` scene cannot set that mask.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    static var actions = SettingsActions()

    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
        NSLog("Cymatica: settings window \(shared?.window?.windowNumber ?? 0)")
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 700, height: 540)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Sozlamalar"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("CymaticaSettings")
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView(actions: Self.actions))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        AppActivationPolicy.enter()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }
}
