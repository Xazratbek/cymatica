import Foundation
import simd

enum ClockStyle: Int, CaseIterable {
    case digital = 0
    case analog = 1
    case rings = 2
}

/// A capsule the sand gathers on: from `ends.xy` to `ends.zw`, half width `extra.x`.
/// Plate units (-1...1); −y is up on screen in the reading pose. Mirrors `ClockStroke`
/// in Shaders.swift.
struct ClockStroke {
    var ends: SIMD4<Float>
    var extra: SIMD4<Float>

    init(_ a: SIMD2<Float>, _ b: SIMD2<Float>, halfWidth: Float) {
        ends = SIMD4(a.x, a.y, b.x, b.y)
        extra = SIMD4(halfWidth, 0, 0, 0)
    }
}

/// Draws the time as strokes. Only the strokes that change move sand: when a second
/// ticks, the grains on the old second digit (or hand) are shaken loose and settle on
/// the new one, while everything else stays put.
struct ClockFace {
    var style: ClockStyle = .digital
    var showSeconds = true

    func strokes(hour: Int, minute: Int, second: Int) -> [ClockStroke] {
        switch style {
        case .digital: digital(hour: hour, minute: minute, second: second)
        case .analog: analog(hour: hour, minute: minute, second: second)
        case .rings: rings(hour: hour, minute: minute, second: second)
        }
    }

    // MARK: - Digital

    private enum Item { case digit(Int), colon }

    private func digital(hour: Int, minute: Int, second: Int) -> [ClockStroke] {
        var items: [Item] = [.digit(hour / 10), .digit(hour % 10), .colon, .digit(minute / 10), .digit(minute % 10)]
        if showSeconds { items += [.colon, .digit(second / 10), .digit(second % 10)] }
        return line(items, width: 1.62)
    }

    /// Lays out a line of digits and colons centered on the plate, `width` wide.
    private func line(_ items: [Item], width: Float) -> [ClockStroke] {
        // Glyph boxes are 1 wide and 2 tall; scale the whole line to the requested width.
        let digitWidth: Float = 1, colonWidth: Float = 0.35, gap: Float = 0.32
        let total = items.reduce(Float(0)) { sum, item in
            if case .colon = item { return sum + colonWidth }
            return sum + digitWidth
        } + gap * Float(items.count - 1)
        let scale = width / total
        // Small digits still need a stroke wide enough to hold visible sand.
        let halfWidth = max(0.065 * scale, 0.008)

        var strokes: [ClockStroke] = []
        var x = -total / 2
        func plate(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2((x + p.x) * scale, -(p.y - 1) * scale)
        }
        for item in items {
            switch item {
            case let .digit(value):
                for line in Self.glyphs[value] {
                    for index in 0..<(line.count - 1) {
                        strokes.append(ClockStroke(plate(line[index]), plate(line[index + 1]), halfWidth: halfWidth))
                    }
                }
                x += digitWidth + gap
            case .colon:
                for y: Float in [0.55, 1.45] {
                    let center = SIMD2<Float>(colonWidth / 2, y)
                    strokes.append(ClockStroke(plate(center - [0, 0.05]), plate(center + [0, 0.05]), halfWidth: halfWidth * 1.4))
                }
                x += colonWidth + gap
            }
        }
        return strokes
    }

    /// A rounded stroke font, one polyline list per digit, in a 1 × 2 box with y up.
    private static let glyphs: [[[SIMD2<Float>]]] = [
        [arc(0.5, 1, 0.5, 1, from: 0, to: 360, steps: 18)],
        [[[0.22, 1.62], [0.56, 2], [0.56, 0]]],
        [arc(0.5, 1.48, 0.5, 0.52, from: 160, to: -25, steps: 9) + [[0, 0], [1, 0]]],
        [arc(0.5, 1.5, 0.46, 0.5, from: 155, to: -90, steps: 9),
         arc(0.5, 0.52, 0.52, 0.52, from: 90, to: -155, steps: 10)],
        [[[0.78, 0], [0.78, 2], [0, 0.62], [1, 0.62]]],
        [[[0.92, 2], [0.12, 2], [0.06, 1.12]] + arc(0.47, 0.66, 0.53, 0.66, from: 140, to: -145, steps: 12)],
        [[[0.85, 1.98], [0.5, 1.72], [0.2, 1.3], [0.04, 0.75]],
         arc(0.5, 0.62, 0.48, 0.62, from: 0, to: 360, steps: 16)],
        [[[0, 2], [1, 2], [0.32, 0]]],
        [arc(0.5, 1.52, 0.42, 0.48, from: 0, to: 360, steps: 14),
         arc(0.5, 0.54, 0.5, 0.54, from: 0, to: 360, steps: 16)],
        [arc(0.5, 1.38, 0.48, 0.62, from: 0, to: 360, steps: 16),
         [[0.96, 1.25], [0.8, 0.7], [0.5, 0.28], [0.15, 0.02]]],
    ]

    private static func arc(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float,
                            from start: Float, to end: Float, steps: Int) -> [SIMD2<Float>] {
        (0...steps).map { index in
            let angle = (start + (end - start) * Float(index) / Float(steps)) * .pi / 180
            return SIMD2(cx + rx * cos(angle), cy + ry * sin(angle))
        }
    }

    // MARK: - Analog

    /// Unit vector for a clock angle in degrees, 0 = 12 o'clock, clockwise.
    private static func direction(_ degrees: Float) -> SIMD2<Float> {
        let angle = degrees * .pi / 180
        return SIMD2(sin(angle), -cos(angle))
    }

    private func analog(hour: Int, minute: Int, second: Int) -> [ClockStroke] {
        let radius: Float = 0.8
        var strokes: [ClockStroke] = []
        for tick in 0..<60 {
            let d = Self.direction(Float(tick) * 6)
            if tick % 5 == 0 {
                let length: Float = tick % 15 == 0 ? 0.14 : 0.09
                strokes.append(ClockStroke(d * (radius - length), d * radius, halfWidth: 0.013))
            } else {
                strokes.append(ClockStroke(d * (radius - 0.012), d * radius, halfWidth: 0.006))
            }
        }
        // Hands move in whole steps, so the sand only jumps when the value changes.
        let hourDirection = Self.direction(Float(hour % 12) * 30 + Float(minute) * 0.5)
        let minuteDirection = Self.direction(Float(minute) * 6)
        strokes.append(ClockStroke(hourDirection * -0.06, hourDirection * 0.42, halfWidth: 0.018))
        strokes.append(ClockStroke(minuteDirection * -0.08, minuteDirection * 0.64, halfWidth: 0.012))
        if showSeconds {
            let secondDirection = Self.direction(Float(second) * 6)
            strokes.append(ClockStroke(secondDirection * -0.14, secondDirection * 0.74, halfWidth: 0.006))
        }
        strokes.append(ClockStroke(.zero, .zero, halfWidth: 0.03))
        return strokes
    }

    // MARK: - Rings

    /// Hours, minutes and seconds as arcs that grow clockwise from 12 o'clock, around
    /// the time written small in the middle so the rings read as a clock at a glance.
    private func rings(hour: Int, minute: Int, second: Int) -> [ClockStroke] {
        var rings: [(radius: Float, fraction: Float, halfWidth: Float)] = [
            (0.42, (Float(hour % 12) + Float(minute) / 60) / 12, 0.02),
            (0.59, Float(minute) / 60, 0.015),
        ]
        if showSeconds { rings.append((0.75, Float(second) / 60, 0.011)) }

        var strokes = line([.digit(hour / 10), .digit(hour % 10), .colon, .digit(minute / 10), .digit(minute % 10)],
                           width: 0.5)
        for ring in rings {
            // A short radial mark at 12 o'clock shows where each ring starts.
            let up = Self.direction(0)
            strokes.append(ClockStroke(up * (ring.radius - 0.03), up * (ring.radius + 0.03), halfWidth: ring.halfWidth))
            let steps = Int(ring.fraction * 36)
            guard steps > 0 else { continue }
            var previous = up * ring.radius
            for step in 1...steps {
                let next = Self.direction(ring.fraction * 360 * Float(step) / Float(steps)) * ring.radius
                strokes.append(ClockStroke(previous, next, halfWidth: ring.halfWidth))
                previous = next
            }
        }
        // A thin closed rim gives loose sand in the empty sectors somewhere even to go,
        // instead of piling it onto the nearest arc end.
        for step in 0..<48 {
            let a = Self.direction(Float(step) * 7.5), b = Self.direction(Float(step + 1) * 7.5)
            strokes.append(ClockStroke(a * 0.9, b * 0.9, halfWidth: 0.005))
        }
        return strokes
    }
}
