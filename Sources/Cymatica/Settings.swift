import Foundation

/// User preferences, persisted in UserDefaults.
final class Settings {
    private let defaults = UserDefaults.standard

    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    /// Show the plate automatically when music plays and the Mac is left alone.
    var autoMode: Bool {
        get { value("autoMode", true) }
        set { defaults.set(newValue, forKey: "autoMode") }
    }

    var idleSeconds: Double {
        get { value("idleSeconds", 20.0) }
        set { defaults.set(newValue, forKey: "idleSeconds") }
    }

    /// Stay hidden while another app keeps the display awake (usually a video playing).
    var respectVideo: Bool {
        get { value("respectVideo", true) }
        set { defaults.set(newValue, forKey: "respectVideo") }
    }

    var shape: PlateField.Shape {
        get { PlateField.Shape(rawValue: value("shape", 0)) ?? .square }
        set { defaults.set(newValue.rawValue, forKey: "shape") }
    }

    var grainCount: Int {
        get { value("grainCount", 100_000) }
        set { defaults.set(newValue, forKey: "grainCount") }
    }

    var framesPerSecond: Int {
        get { value("framesPerSecond", 60) }
        set { defaults.set(newValue, forKey: "framesPerSecond") }
    }

    /// Briefly show the note, its frequency and the plate mode after each change.
    var showCaption: Bool {
        get { value("showCaption", true) }
        set { defaults.set(newValue, forKey: "showCaption") }
    }

    /// CGDirectDisplayID of the chosen screen; 0 picks the built-in display.
    /// Stored as Int so the SwiftUI settings can bind to it with @AppStorage.
    var screenID: UInt32 {
        get { UInt32(truncatingIfNeeded: value("screenID", 0)) }
        set { defaults.set(Int(newValue), forKey: "screenID") }
    }

    var mode: DisplayMode {
        get { DisplayMode(rawValue: value("mode", DisplayMode.mixed.rawValue)) ?? .mixed }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var clockStyle: ClockStyle {
        get { ClockStyle(rawValue: value("clockStyle", 0)) ?? .digital }
        set { defaults.set(newValue.rawValue, forKey: "clockStyle") }
    }

    var showSeconds: Bool {
        get { value("showSeconds", true) }
        set { defaults.set(newValue, forKey: "showSeconds") }
    }

    /// Also show the plate (usually as a clock) when nothing is playing. Keeps the
    /// display awake while shown, like a phone's always-on display.
    var showWithoutMusic: Bool {
        get { value("showWithoutMusic", false) }
        set { defaults.set(newValue, forKey: "showWithoutMusic") }
    }

    /// When false, only the trackpad or mouse closes the plate; keys are ignored.
    var keyboardDismisses: Bool {
        get { value("keyboardDismisses", true) }
        set { defaults.set(newValue, forKey: "keyboardDismisses") }
    }

    /// React to every beat and to the music's intensity, not only to harmony.
    var followRhythm: Bool {
        get { value("followRhythm", false) }
        set { defaults.set(newValue, forKey: "followRhythm") }
    }

    var placement: Placement {
        get { Placement(rawValue: value("placement", 0)) ?? .center }
        set { defaults.set(newValue.rawValue, forKey: "placement") }
    }

    /// Plate size relative to the default framing, 0.4 ... 1.2.
    var plateSize: Double {
        get { value("plateSize", 1.0) }
        set { defaults.set(newValue, forKey: "plateSize") }
    }
}

enum DisplayMode: Int, CaseIterable {
    /// Chladni figures from the music.
    case music = 0
    /// The sand draws the time.
    case clock = 1
    /// Chladni figures while music plays, the clock when it stops.
    case mixed = 2

    var title: String {
        switch self {
        case .music: "Musiqa"
        case .clock: "Soat"
        case .mixed: "Aralash"
        }
    }
}

/// Where on the screen the plate sits.
enum Placement: Int, CaseIterable {
    case center, left, right, topLeft, topRight, bottomLeft, bottomRight, top, bottom

    /// The 3 × 3 grid the settings show, top row first.
    static let grid: [[Placement]] = [[.topLeft, .top, .topRight], [.left, .center, .right],
                                      [.bottomLeft, .bottom, .bottomRight]]

    var title: String {
        switch self {
        case .center: "Markazda"
        case .left: "Chapda"
        case .right: "O'ngda"
        case .topLeft: "Yuqori chapda"
        case .topRight: "Yuqori o'ngda"
        case .bottomLeft: "Pastki chapda"
        case .bottomRight: "Pastki o'ngda"
        case .top: "Tepada"
        case .bottom: "Pastda"
        }
    }

    /// Clip-space offset and scale for a plate drawn at `size` of the default framing.
    func transform(size: Float) -> SIMD3<Float> {
        let x = 1 - 0.68 * size - 0.04, y = 1 - 0.82 * size - 0.04
        switch self {
        case .center: return SIMD3(0, 0, size)
        case .left: return SIMD3(-x, 0, size)
        case .right: return SIMD3(x, 0, size)
        case .topLeft: return SIMD3(-x, y, size)
        case .topRight: return SIMD3(x, y, size)
        case .bottomLeft: return SIMD3(-x, -y, size)
        case .bottomRight: return SIMD3(x, -y, size)
        case .top: return SIMD3(0, y, size)
        case .bottom: return SIMD3(0, -y, size)
        }
    }
}
