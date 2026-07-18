import Testing
@testable import Metrics

/// UpdateChecker's dotted-version comparison (v2.1). Pure string/number logic;
/// the network side is deliberately untested here.
@MainActor
struct VersionCompareTests {
    @Test func stripsLeadingV() {
        #expect(UpdateChecker.strippedVersion("v2.1.0") == "2.1.0")
        #expect(UpdateChecker.strippedVersion(" V3.0 ") == "3.0")
        #expect(UpdateChecker.strippedVersion("2.0") == "2.0")
    }

    @Test func parsesDottedNumerics() {
        #expect(UpdateChecker.parse("2.1.0") == [2, 1, 0])
        #expect(UpdateChecker.parse("v7") == [7])
    }

    @Test func rejectsMalformedVersions() {
        #expect(UpdateChecker.parse("") == nil)
        #expect(UpdateChecker.parse("nightly") == nil)
        #expect(UpdateChecker.parse("2.1.0-beta") == nil)
        #expect(UpdateChecker.parse("2..1") == nil)     // empty component
        #expect(UpdateChecker.parse("2.-1") == nil)     // negative component
    }

    @Test func ordersVersionsNumerically() {
        #expect(UpdateChecker.isNewer(remote: "2.1.1", than: "2.1.0"))
        #expect(!UpdateChecker.isNewer(remote: "2.1.0", than: "2.1.0"))    // equal
        #expect(!UpdateChecker.isNewer(remote: "2.0.9", than: "2.1.0"))    // older
        // Numeric, not lexicographic: "10" > "9".
        #expect(UpdateChecker.isNewer(remote: "2.10.0", than: "2.9.0"))
        // Tag prefix is stripped before comparing.
        #expect(UpdateChecker.isNewer(remote: "v2.2.0", than: "2.1.0"))
    }

    @Test func missingSegmentsCountAsZero() {
        #expect(!UpdateChecker.isNewer(remote: "2.1", than: "2.1.0"))
        #expect(!UpdateChecker.isNewer(remote: "2.1.0", than: "2.1"))
        #expect(UpdateChecker.isNewer(remote: "2.1.0.1", than: "2.1"))
    }

    @Test func malformedNeverComparesAsNewer() {
        #expect(!UpdateChecker.isNewer(remote: "nightly", than: "2.1.0"))
        #expect(!UpdateChecker.isNewer(remote: "3.0", than: "junk"))
    }
}
