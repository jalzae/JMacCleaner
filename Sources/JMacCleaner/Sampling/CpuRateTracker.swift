import Foundation
import Darwin

/// Turns raw cumulative CPU microseconds into a CPU% reading by keeping the
/// previous tick's baselines. Matches Activity Monitor semantics (a busy
/// multithreaded process can exceed 100).
struct CpuRateTracker: Sendable {
    private struct Baseline: Sendable {
        let cpuMicros: UInt64
        let wallNanos: UInt64
        let startSeconds: Double
    }

    private var baselines: [Int32: Baseline] = [:]

    /// Fill in `cpuPercent` on each row using the delta against the previous tick.
    /// Rows without a baseline (first tick, pid reuse) get 0.0.
    /// `cpuProvider` is injectable so tests can feed synthetic CPU numbers.
    mutating func annotate(
        _ rows: inout [ProcessRow],
        cpuProvider: (Int32) -> UInt64? = ProcessSamplerCpuHook.rawCpuMicros
    ) {
        let wallNow = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        for index in rows.indices {
            let row = rows[index]
            guard let usage = cpuProvider(row.pid) else {
                rows[index].cpuPercent = 0
                continue
            }

            let previous = baselines[row.pid]
            // pid reused since last tick -> reset baseline, report 0 once.
            if let previous, previous.startSeconds == row.startSeconds {
                let wallDelta = wallNow > previous.wallNanos ? wallNow - previous.wallNanos : 0
                let cpuDelta = usage > previous.cpuMicros ? usage - previous.cpuMicros : 0
                if wallDelta > 0 {
                    // cpu delta is microseconds; wall delta is nanoseconds.
                    let cpuNanos = Double(cpuDelta) * 1_000.0
                    rows[index].cpuPercent = min(999, cpuNanos / Double(wallDelta) * 100.0)
                } else {
                    rows[index].cpuPercent = 0
                }
            } else {
                rows[index].cpuPercent = 0
            }
            baselines[row.pid] = Baseline(
                cpuMicros: usage,
                wallNanos: wallNow,
                startSeconds: row.startSeconds
            )
        }
    }

    /// Forget pids that no longer exist so the dictionary cannot grow forever.
    mutating func prune(alivePids: Set<Int32>) {
        baselines = baselines.filter { alivePids.contains($0.key) }
    }
}

/// Isolated indirection so tests can stub raw CPU numbers without spawning
/// real processes.
enum ProcessSamplerCpuHook {
    /// Raw cumulative user+system CPU time in microseconds.
    static func rawCpuMicros(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutableBytes(of: &info) { raw -> Int32 in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard rc == 0 else { return nil }
        return info.ri_user_time &+ info.ri_system_time
    }
}
