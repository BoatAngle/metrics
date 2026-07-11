import Foundation

/// Fixed-capacity ring buffer of Doubles for metric histories.
struct RingBuffer {
    private var storage: [Double]
    private var index = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: 0, count: self.capacity)
    }

    mutating func append(_ value: Double) {
        storage[index] = value
        index = (index + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Values ordered oldest → newest.
    var ordered: [Double] {
        guard count == capacity else { return Array(storage[0..<count]) }
        return Array(storage[index...]) + Array(storage[..<index])
    }
}
