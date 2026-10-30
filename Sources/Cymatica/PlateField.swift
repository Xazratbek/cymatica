import Foundation
import Metal

/// One standing-wave pattern of the plate.
struct PlateMode: Equatable {
    /// Square: wave number n. Circle: angular order (number of nodal diameters).
    var a: Float
    /// Square: wave number m. Circle: radial wave number k (a zero of J_a).
    var b: Float
    /// Square: +1 or −1 combination of the two degenerate modes. Circle: angular phase.
    var variant: Float
    /// Eigenvalue; the mode's frequency is proportional to it.
    var lambda: Float
    var label: String
}

/// Which modes are ringing and how strongly.
///
/// Physics model: a Chladni plate driven at a frequency vibrates in the eigenmode closest
/// to it. Higher notes excite higher modes, which have more nodal lines. When the mode
/// changes, the old nodal lines start to shake and the sand migrates to the new ones.
/// During the crossfade the time-averaged vibration energy is Σ wᵢ·Zᵢ², which is what
/// the GPU uses to kick the grains.
final class PlateField {
    enum Shape: Int {
        case square = 0
        case circle = 1
    }

    static let profileLength = 1024
    static let slotCount = 4

    private(set) var shape: Shape
    private(set) var current: PlateMode?
    private var table: [[PlateMode]]
    private var slots: [Slot?] = Array(repeating: nil, count: PlateField.slotCount)
    private let profiles: MTLBuffer
    var crossfadeSeconds: Float = 0.6

    private struct Slot {
        var mode: PlateMode
        var weight: Float
        var target: Float
    }

    init(shape: Shape, profiles: MTLBuffer) {
        self.shape = shape
        self.profiles = profiles
        table = Self.table(for: shape)
    }

    func setShape(_ newShape: Shape) {
        guard newShape != shape else { return }
        shape = newShape
        table = Self.table(for: newShape)
        slots = Array(repeating: nil, count: Self.slotCount)
        current = nil
    }

    func mode(tier: Int, pitchClass: Int) -> PlateMode {
        table[min(max(tier, 0), table.count - 1)][((pitchClass % 12) + 12) % 12]
    }

    /// Starts crossfading to the mode for this note. Returns true if the mode changed.
    @discardableResult
    func select(tier: Int, pitchClass: Int) -> Bool {
        let next = mode(tier: tier, pitchClass: pitchClass)
        guard next != current else { return false }
        current = next
        for index in slots.indices { slots[index]?.target = 0 }
        let free = slots.firstIndex { $0 == nil }
            ?? slots.indices.min { (slots[$0]?.weight ?? 0) < (slots[$1]?.weight ?? 0) }!
        slots[free] = Slot(mode: next, weight: 0, target: 1)
        if shape == .circle { writeProfile(next, slot: free) }
        return true
    }

    func step(dt: Float) {
        let rate = dt / max(crossfadeSeconds, 0.01)
        for index in slots.indices {
            guard var slot = slots[index] else { continue }
            slot.weight = min(max(slot.weight + (slot.target > slot.weight ? rate : -rate), 0), 1)
            slots[index] = slot.target == 0 && slot.weight == 0 ? nil : slot
        }
    }

    /// (a, b, variant, normalized weight) for each GPU slot.
    var gpuModes: [SIMD4<Float>] {
        let total = slots.reduce(Float(0)) { $0 + ($1?.weight ?? 0) }
        return slots.map { slot in
            guard let slot, total > 0 else { return .zero }
            return SIMD4(slot.mode.a, slot.mode.b, slot.mode.variant, slot.weight / total)
        }
    }

    // MARK: - Circle radial profiles

    private func writeProfile(_ mode: PlateMode, slot: Int) {
        let count = Self.profileLength
        let values = profiles.contents().bindMemory(to: Float.self, capacity: count * Self.slotCount) + slot * count
        var peak: Float = 1e-6
        for index in 0..<count {
            let r = Double(index) / Double(count - 1)
            let value = Float(Bessel.j(Int(mode.a), Double(mode.b) * r, steps: 96))
            values[index] = value
            peak = max(peak, abs(value))
        }
        for index in 0..<count { values[index] /= peak }
    }

    // MARK: - Mode tables

    /// 3 tiers × 12 pitch classes. Within a tier, pitch classes ascend with eigenvalue, so a
    /// higher note always rings a mode with more nodal lines.
    private static func table(for shape: Shape) -> [[PlateMode]] {
        switch shape {
        case .square:
            // Free square plate, Ritz approximation (the classic Chladni figure formula):
            // Z = cos(nπx)cos(mπy) ± cos(mπx)cos(nπy), frequency ∝ m² + n².
            var candidates: [PlateMode] = []
            for m in 1...18 {
                for n in 0..<m {
                    for variant: Float in [-1, 1] {
                        candidates.append(PlateMode(a: Float(n), b: Float(m), variant: variant,
                                                    lambda: Float(m * m + n * n),
                                                    label: "(\(m), \(n))\(variant > 0 ? "+" : "−")"))
                    }
                }
            }
            return pickTiers(candidates, ranges: [(8, 50), (50, 130), (130, 300)])
        case .circle:
            // Circular plate, membrane approximation: Z = J_n(k·r)·cos(nθ), frequency ∝ k².
            var candidates: [PlateMode] = []
            for order in 0...16 {
                for (index, zero) in Bessel.zeros(order: order, count: 10, upTo: 30).enumerated() {
                    // High angular orders with few rings leave a wide still disc in the
                    // middle where sand never moves; skip them.
                    guard order <= index + 5 else { continue }
                    candidates.append(PlateMode(a: Float(order), b: Float(zero), variant: 0,
                                                lambda: Float(zero * zero),
                                                label: "(\(order), \(index + 1))"))
                }
            }
            return pickTiers(candidates, ranges: [(9, 100), (100, 289), (289, 784)])
        }
    }

    private static func pickTiers(_ candidates: [PlateMode], ranges: [(Float, Float)]) -> [[PlateMode]] {
        ranges.map { low, high in
            var pool = candidates
                .filter { $0.lambda >= low && $0.lambda <= high }
                .sorted { ($0.lambda, $0.variant, $0.b) < ($1.lambda, $1.variant, $1.b) }
            var picked: [PlateMode] = []
            for step in 0..<12 {
                let target = logf(low) + (logf(high) - logf(low)) * Float(step) / 11
                guard let best = pool.indices.min(by: {
                    abs(logf(pool[$0].lambda) - target) < abs(logf(pool[$1].lambda) - target)
                }) else { break }
                picked.append(pool.remove(at: best))
            }
            return picked.sorted { $0.lambda < $1.lambda }
        }
    }
}

enum Bessel {
    /// J_n(x) = (1/π) ∫₀^π cos(nτ − x·sin τ) dτ, midpoint rule.
    static func j(_ order: Int, _ x: Double, steps: Int = 160) -> Double {
        var sum = 0.0
        for index in 0..<steps {
            let tau = (Double(index) + 0.5) * .pi / Double(steps)
            sum += cos(Double(order) * tau - x * sin(tau))
        }
        return sum / Double(steps)
    }

    static func zeros(order: Int, count: Int, upTo limit: Double) -> [Double] {
        var result: [Double] = []
        var x = 0.05
        var value = j(order, x)
        while x < limit, result.count < count {
            let next = x + 0.05
            let nextValue = j(order, next)
            if value.sign != nextValue.sign {
                var low = x, high = next
                for _ in 0..<40 {
                    let mid = 0.5 * (low + high)
                    if j(order, mid).sign == j(order, low).sign { low = mid } else { high = mid }
                }
                result.append(0.5 * (low + high))
            }
            x = next
            value = nextValue
        }
        return result
    }
}
