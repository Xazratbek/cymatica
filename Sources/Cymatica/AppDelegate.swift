import AppKit

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let settings = Settings()
    private let ring = AudioRing()
    private var tap: SystemAudioTap?
    private var filePlayer: FileAudioPlayer?
    private var visualizer: Visualizer!
    private var aod: AODController!
    private var levels: LevelMonitor!
    private var statusItem: NSStatusItem!
    private var audioProblem: String?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available") }

        let renderer: Renderer
        do {
            renderer = try Renderer(device: device, grainCount: options.grains ?? settings.grainCount)
        } catch {
            fatalError("Renderer setup failed: \(error)")
        }
        let plate = PlateField(shape: options.shape ?? settings.shape, profiles: renderer.profiles)

        var sampleRate = 48_000.0
        if let path = options.file {
            do {
                let player = try FileAudioPlayer(url: URL(fileURLWithPath: path), ring: ring)
                try player.start()
                sampleRate = player.sampleRate
                filePlayer = player
            } catch {
                audioProblem = "Fayl ochilmadi: \(error.localizedDescription)"
            }
        } else if !options.demo {
            let tap = SystemAudioTap(ring: ring)
            do {
                try tap.start()
                sampleRate = tap.sampleRate
            } catch {
                audioProblem = "Tizim ovozi ulanmadi: \(error)"
                NSLog("Cymatica: \(error)")
            }
            self.tap = tap
        }

        let analyzer = MusicAnalyzer(ring: ring, sampleRate: Float(sampleRate))
        tap?.onRestart = { rate in analyzer.sampleRate = Float(rate) }
        levels = LevelMonitor(ring: ring)
        visualizer = Visualizer(renderer: renderer, plate: plate, analyzer: analyzer, demo: options.demo)
        visualizer.dumpPath = options.dumpFrame

        let alwaysPlaying = options.demo
        aod = AODController(device: device, settings: settings) { [unowned self] in
            alwaysPlaying || self.levels.poll(now: CACurrentMediaTime())
        }
        aod.view.delegate = visualizer
        aod.ignoresInput = options.stay
        aod.onVisibilityChange = { [unowned self] shown in
            guard shown else { return }
            self.visualizer.resetClock()
            // Respect "Reduce Motion": the sand still moves, but the camera stops orbiting.
            self.visualizer.renderer.camera.orbits = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        visualizer.onModeChange = { [unowned self] caption in
            if self.settings.showCaption { self.aod.flashCaption(caption) }
        }

        let audioStatus = audioProblem ?? (options.demo ? "Demo (ovozsiz)" : options.file != nil ? "Fayl" : "Tizim ovozi (Core Audio tap)")
        SettingsWindowController.actions = SettingsActions(
            showNow: { [unowned self] in self.aod.show(auto: false) },
            rescatter: { [unowned self] in self.visualizer.renderer.scatter() },
            audioStatus: { audioStatus })
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [unowned self] _ in self.applySettings() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Cymatica")
        icon?.isTemplate = true // follows the light/dark menu bar
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applySettings()
        aod.start()
        if options.openSettings {
            SettingsWindowController.show()
        }
        if options.showNow || options.demo || options.file != nil {
            aod.show(auto: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap?.stop()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionItem("Hozir yoqish", key: "s") { [unowned self] in self.aod.show(auto: false) })
        if let audioProblem {
            let item = NSMenuItem(title: audioProblem, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for mode in DisplayMode.allCases {
            menu.addItem(ActionItem("Rejim: \(mode.title)", checked: settings.mode == mode) { [unowned self] in
                self.settings.mode = mode
            })
        }
        menu.addItem(ActionItem("Musiqa ritmiga moslashsin", checked: settings.followRhythm) { [unowned self] in
            self.settings.followRhythm.toggle()
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Avtomatik yoqilsin", checked: settings.autoMode) { [unowned self] in
            self.settings.autoMode.toggle()
        })
        menu.addItem(ActionItem("Sozlamalar…", key: ",") { SettingsWindowController.show() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Chiqish", key: "q") { NSApp.terminate(nil) })
    }

    /// Applies settings that need the renderer or the view to change. The rest
    /// (auto mode, idle time, caption, screen) are read live where they are used.
    private func applySettings() {
        visualizer.renderer.setGrainCount(settings.grainCount)
        visualizer.plate.setShape(settings.shape)
        visualizer.mode = settings.mode
        visualizer.followRhythm = settings.followRhythm
        visualizer.clockFace = ClockFace(style: settings.clockStyle, showSeconds: settings.showSeconds)
        visualizer.placement = settings.placement.transform(size: Float(settings.plateSize))
        aod.setFramesPerSecond(settings.framesPerSecond)
    }
}
