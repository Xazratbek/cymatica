import Synchronization

/// Lock-free single-producer ring of mono samples.
///
/// The audio IO thread is the only writer. Readers on the main thread copy the newest
/// window without consuming it. Writing never allocates or locks, so it is safe to call
/// from a real-time audio callback.
final class AudioRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeCursor = Atomic<Int>(0)

    init(capacity: Int = 1 << 17) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Total samples written since creation. Readers compare it between polls to tell a
    /// stalled stream from real silence.
    var totalWritten: Int {
        writeCursor.load(ordering: .acquiring)
    }

    /// Mixes stereo (or copies mono when `right` is nil) into the ring.
    /// `stride` is the distance between consecutive frames, in samples.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, stride: Int) {
        var cursor = writeCursor.load(ordering: .relaxed)
        if let right {
            for frame in 0..<frames {
                storage[cursor & mask] = 0.5 * (left[frame * stride] + right[frame * stride])
                cursor &+= 1
            }
        } else {
            for frame in 0..<frames {
                storage[cursor & mask] = left[frame * stride]
                cursor &+= 1
            }
        }
        writeCursor.store(cursor, ordering: .releasing)
    }

    /// Copies the newest `count` samples, oldest first, into `destination`.
    func readLatest(into destination: UnsafeMutablePointer<Float>, count: Int) {
        let end = writeCursor.load(ordering: .acquiring)
        let start = end - count
        for offset in 0..<count {
            let index = start + offset
            destination[offset] = index >= 0 ? storage[index & mask] : 0
        }
    }
}
