import Foundation

/// One process as captured by a single sampling tick. Pure value type so it can
/// cross isolation boundaries freely under Swift 6 strict concurrency.
struct ProcessRow: Identifiable, Sendable, Hashable {
    let pid: Int32
    let ppid: Int32
    /// Basename of the executable path; falls back to the kernel short name
    /// (`p_comm`) when the path is hidden (process owned by another user).
    let name: String
    /// Full executable path, or nil when `proc_pidpath` is not permitted.
    let path: String?
    let uid: UInt32
    let uidName: String
    /// Filled in by `CpuRateTracker`; 0.0 on the very first tick (no baseline yet).
    var cpuPercent: Double
    /// Listening TCP ports, filled in by `PortScanner`; empty when the process
    /// does not listen or the socket owner could not be attributed.
    var ports: [UInt16]
    let residentBytes: UInt64
    let isZombie: Bool
    /// Process start time in seconds since the epoch. Two snapshots with the same
    /// pid but different start times mean the pid was reused.
    let startSeconds: Double

    var id: Int32 { pid }

    /// Best-effort executable display name for classification: basename of the
    /// real path when visible, else the kernel short name (lowercased).
    var classifyName: String {
        if let path { return (path as NSString).lastPathComponent.lowercased() }
        return name.lowercased()
    }

    var classifyPath: String? { path }

    /// "3000, 9229" — empty string when not listening.
    var portSummary: String {
        ports.map(String.init).joined(separator: ", ")
    }
}
