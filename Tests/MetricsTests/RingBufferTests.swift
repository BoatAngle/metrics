import Testing
@testable import Metrics

/// Fixed-capacity ring buffer backing the metric histories.
struct RingBufferTests {
    @Test func emptyBufferIsEmpty() {
        let buffer = RingBuffer(capacity: 4)
        #expect(buffer.count == 0)
        #expect(buffer.ordered == [])
    }

    @Test func partialFillPreservesOrder() {
        var buffer = RingBuffer(capacity: 4)
        buffer.append(1)
        buffer.append(2)
        #expect(buffer.count == 2)
        #expect(buffer.ordered == [1, 2])
    }

    @Test func wraparoundEvictsOldestFirst() {
        var buffer = RingBuffer(capacity: 3)
        for v in [1.0, 2, 3, 4, 5] { buffer.append(v) }
        #expect(buffer.count == 3)
        #expect(buffer.ordered == [3, 4, 5])
    }

    @Test func zeroCapacityClampsToOne() {
        var buffer = RingBuffer(capacity: 0)
        #expect(buffer.capacity == 1)
        buffer.append(7)
        buffer.append(8)
        #expect(buffer.ordered == [8])
    }
}
