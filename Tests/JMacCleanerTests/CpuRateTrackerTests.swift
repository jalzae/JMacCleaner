import XCTest
@testable import JMacCleaner

final class CpuRateTrackerTests: XCTestCase {
    private func row(pid: Int32, start: Double = 100) -> ProcessRow {
        ProcessRow(
            pid: pid, ppid: 1, name: "proc", path: "/tmp/proc",
            uid: 501, uidName: "me", cpuPercent: 0, ports: [],
            residentBytes: 1000, isZombie: false, startSeconds: start
        )
    }

    private func provider(samples: [Int32: UInt64]) -> (Int32) -> UInt64? {
        { pid in samples[pid] }
    }

    private func wall(clock: inout UInt64) -> (Int32) -> UInt64? {
        // CpuRateTracker reads the monotonic clock internally; we cannot stub it,
        // so instead we validate the arithmetic indirectly via real ticks.
        _ = clock
        return { _ in nil }
    }

    func testFirstTickReportsZero() {
        var tracker = CpuRateTracker()
        var rows = [row(pid: 300)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [300: 1_000_000]))
        XCTAssertEqual(rows[0].cpuPercent, 0)
    }

    func testSecondTickComputesPositiveRate() {
        var tracker = CpuRateTracker()
        var rows = [row(pid: 301)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [301: 0]))

        // Give the monotonic clock a real moment so wallDelta > 0.
        Thread.sleep(forTimeInterval: 0.02)
        var second = [row(pid: 301)]
        tracker.annotate(&second, cpuProvider: provider(samples: [301: 500_000])) // 0.5s CPU
        // 0.5 s CPU across ~0.02 s wall => a big positive number, and definitely > 0.
        XCTAssertGreaterThan(second[0].cpuPercent, 0)
    }

    func testPidReuseResetsToZero() {
        var tracker = CpuRateTracker()
        var rows = [row(pid: 302, start: 100)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [302: 1_000_000]))

        // Same pid, different startSeconds => reused pid => report 0 once.
        var reused = [row(pid: 302, start: 200)]
        tracker.annotate(&reused, cpuProvider: provider(samples: [302: 2_000_000]))
        XCTAssertEqual(reused[0].cpuPercent, 0)
    }

    func testMissingProviderSampleReportsZero() {
        var tracker = CpuRateTracker()
        var rows = [row(pid: 303)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [:]))
        XCTAssertEqual(rows[0].cpuPercent, 0)
    }

    func testPruneDropsDeadPids() {
        var tracker = CpuRateTracker()
        var rows = [row(pid: 304), row(pid: 305)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [304: 0, 305: 0]))
        tracker.prune(alivePids: [304])
        // No direct access to internals; verify behaviorally: a fresh row for a
        // pruned pid reports 0 again on the next tick.
        var fresh = [row(pid: 305)]
        tracker.annotate(&fresh, cpuProvider: provider(samples: [305: 5_000_000]))
        XCTAssertEqual(fresh[0].cpuPercent, 0)
    }

    func testRateCalculationMatchesDelta() {
        // Deterministic: feed two ticks with a real wall gap (Thread.sleep).
        var tracker = CpuRateTracker()
        var rows = [row(pid: 306)]
        tracker.annotate(&rows, cpuProvider: provider(samples: [306: 0]))
        Thread.sleep(forTimeInterval: 0.05)
        var second = [row(pid: 306)]
        tracker.annotate(&second, cpuProvider: provider(samples: [306: 250_000])) // 0.25 s CPU
        // 0.25s / ~0.05s * 100 ≈ 500%; bounds are loose but directional.
        XCTAssertGreaterThan(second[0].cpuPercent, 100)
        XCTAssertLessThan(second[0].cpuPercent, 5_000)
    }
}
