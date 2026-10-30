import Accelerate
import AppKit
import IOKit.pwr_mgt
import MetalKit

/// Borderless windows refuse key status by default; this one takes it so keystrokes
/// that wake the screen are swallowed instead of reaching the app underneath.
final class AODWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Keys that do not close the plate are swallowed quietly instead of beeping.
    override func keyDown(with event: NSEvent) {}
}

/// Cheap "is music playing?" check that runs while the plate is hidden.
final class LevelMonitor {
    private let ring: AudioRing
    private let window: UnsafeMutablePointer<Float>
    private let count = 12_000
    private var lastWritten = 0
    private var loudSince: CFTimeInterval?
    private var quietSince: CFTimeInterval?
    private(set) var isPlaying = false

    init(ring: AudioRing) {
        self.ring = ring
        window = .allocate(capacity: count)
    }

    deinit {
        window.deallocate()
    }

    func poll(now: CFTimeInterval) -> Bool {
        let written = ring.totalWritten
        var db: Float = -120
        if written != lastWritten {
            ring.readLatest(into: window, count: count)
            var rms: Float = 0
            vDSP_rmsqv(window, 1, &rms, vDSP_Length(count))
            db = 20 * log10f(max(rms, 1e-7))
        }
        lastWritten = written

        if db > -55 {
            quietSince = nil
            if loudSince == nil { loudSince = now }
            if let loudSince, now - loudSince > 1.5 { isPlaying = true }
        } else if db < -60 {
            loudSince = nil
            if quietSince == nil { quietSince = now }
            if let quietSince, now - quietSince > 8 { isPlaying = false }
        }
        return isPlaying
    }
}

/// The always-on-display behaviour: fades the plate in when music plays and the Mac is
/// idle, fades it out on any input, and keeps the display awake only while music plays.
final class AODController {
    let view: MTKView
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isShown = false
    /// Debug (`--stay`): keep the plate up while the user works, for screen captures.
    var ignoresInput = false

    private let window: AODWindow
    private let container = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let settings: Settings
    private let musicIsPlaying: () -> Bool

    private var timer: Timer?
    private var armed = false
    private var autoShown = false
    private var lastMusic: CFTimeInterval = 0
    private var previousApp: NSRunningApplication?
    private var cursorHidden = false
    private var sleepAssertion: IOPMAssertionID = 0
    private var captionGeneration = 0

    init(device: MTLDevice, settings: Settings, musicIsPlaying: @escaping () -> Bool) {
        self.settings = settings
        self.musicIsPlaying = musicIsPlaying

        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = settings.framesPerSecond
        view.isPaused = true

        window = AODWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        caption.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = NSColor(white: 0.5, alpha: 1)
        caption.alignment = .center
        caption.alphaValue = 0
        container.addSubview(view)
        container.addSubview(caption)
        window.contentView = container
    }

    func start() {
        schedule(interval: 0.5)
        // A display was plugged in, unplugged or rearranged: move the plate to the
        // right screen and pick up its scale.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isShown else { return }
            self.place(on: self.targetScreen())
        }
    }

    func setFramesPerSecond(_ value: Int) {
        view.preferredFramesPerSecond = value
    }

    // MARK: - Showing and hiding

    func show(auto: Bool) {
        guard !isShown else { return }
        let screen = targetScreen()
        NSLog("Cymatica: showing on \(screen.localizedName) (auto: \(auto), window \(window.windowNumber))")
        place(on: screen)

        let me = NSRunningApplication.current
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == me.processIdentifier ? nil : $0 }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKey()
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }

        isShown = true
        armed = false
        autoShown = auto
        lastMusic = CACurrentMediaTime()
        view.isPaused = false
        onVisibilityChange?(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 2.5
            window.animator().alphaValue = 1
        }
        schedule(interval: 0.1)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        setSleepAssertion(false)
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.window.orderOut(nil)
            self.view.isPaused = true
        })
        previousApp?.activate(from: .current, options: [])
        previousApp = nil
        onVisibilityChange?(false)
        schedule(interval: 0.5)
    }

    /// Shows a dim caption at the bottom for a few seconds, then fades back to black.
    func flashCaption(_ text: String) {
        captionGeneration += 1
        let generation = captionGeneration
        caption.stringValue = text
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.8
            caption.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.captionGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 2.5
                self.caption.animator().alphaValue = 0
            }
        }
    }

    // MARK: - Polling

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let idle = Self.secondsSinceInput(includingKeyboard: true)
        let playing = musicIsPlaying()
        if playing { lastMusic = now }
        let alwaysOn = settings.showWithoutMusic

        if isShown {
            // With "keyboard does not close" on, only the trackpad or mouse counts.
            let still = settings.keyboardDismisses ? idle : Self.secondsSinceInput(includingKeyboard: false)
            // Arm only once the user has been still for a moment, so the click that
            // opened the plate from the menu does not close it again.
            if !armed, still > 0.8 { armed = true }
            if armed, still < 0.3, !ignoresInput {
                NSLog("Cymatica: hiding on user input")
                hide()
                return
            }
            setSleepAssertion(alwaysOn || now - lastMusic < 5)
            // Music stopped: let the Mac sleep normally, unless asked to stay on.
            if autoShown, !alwaysOn, now - lastMusic > 45 { hide() }
        } else if settings.autoMode, playing || alwaysOn, idle >= settings.idleSeconds,
                  !(settings.respectVideo && Self.anotherAppKeepsDisplayAwake()) {
            show(auto: true)
        }
    }

    private func setSleepAssertion(_ hold: Bool) {
        if hold, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Cymatica is showing music" as CFString, &sleepAssertion)
        } else if !hold, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: - Helpers

    private func place(on screen: NSScreen) {
        window.setFrame(screen.frame, display: false)
        layout(on: screen)
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            // An MTKView created outside a window keeps contentsScale 0, and WindowServer
            // then shows nothing at all. Set it from the target screen.
            layer.contentsScale = screen.backingScaleFactor
        }
    }

    private func layout(on screen: NSScreen) {
        let size = screen.frame.size
        container.frame = NSRect(origin: .zero, size: size)
        // Keep the plate in the area below the notch.
        let top = screen.safeAreaInsets.top
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - top)
        caption.frame = NSRect(x: 0, y: 26, width: size.width, height: 18)
    }

    func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        if settings.screenID != 0, let chosen = screens.first(where: { $0.displayID == settings.screenID }) {
            return chosen
        }
        return screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? NSScreen.main ?? screens[0]
    }

    /// Seconds since the last trackpad or mouse input, and keyboard input if asked.
    private static func secondsSinceInput(includingKeyboard: Bool) -> Double {
        var types: [CGEventType] = [.mouseMoved, .scrollWheel, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .leftMouseDragged]
        if includingKeyboard { types += [.keyDown, .flagsChanged] }
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    /// True when an app (a browser or player showing video) holds a display-sleep
    /// assertion. Command-line tools such as `caffeinate` and system daemons also hold
    /// them for unrelated reasons, so only processes that are apps count.
    private static func anotherAppKeepsDisplayAwake() -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let processes = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return processes.contains { pid, assertions in
            guard pid.int32Value != me, NSRunningApplication(processIdentifier: pid.int32Value) != nil else { return false }
            return assertions.contains { assertion in
                let type = assertion["AssertType"] as? String
                return type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion"
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
