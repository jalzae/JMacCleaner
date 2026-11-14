import Foundation
import Darwin

enum KillOutcome: Sendable, Equatable {
    case terminated
    case forceKilled
    case alreadyGone
    case permissionDenied
    case cancelled
    case failed(String)

    var description: String {
        switch self {
        case .terminated: return "Terminated"
        case .forceKilled: return "Force killed"
        case .alreadyGone: return "Already gone"
        case .permissionDenied: return "Needs administrator"
        case .cancelled: return "Cancelled"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

struct KillResult: Sendable, Identifiable {
    let pid: Int32
    let name: String
    let outcome: KillOutcome
    var id: Int32 { pid }
}

/// Single and batch kill orchestration. Safety rules are re-checked at the
/// moment of the kill, never trusted from the UI list.
enum ProcessKiller {
    /// SIGTERM, wait a grace period, SIGKILL if still alive.
    static func terminate(
        pid: Int32,
        context: ClassificationContext,
        graceNanos: UInt64 = 1_500_000_000
    ) async -> KillOutcome {
        guard pid > 1 else { return .failed("refusing to signal pid \(pid)") }
        if let row = context.rowMap[pid], ProcessSafety.isProtected(row, context: context) != nil {
            return .failed("protected process")
        }

        if kill(pid, SIGTERM) != 0 {
            switch errno {
            case ESRCH: return .alreadyGone
            case EPERM: return .permissionDenied
            default: return .failed("errno \(errno)")
            }
        }

        // Poll for exit; escalate if it ignores SIGTERM.
        let deadline = DispatchTime.now().uptimeNanoseconds + graceNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH {
                return .terminated
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if kill(pid, SIGKILL) == 0 { return .forceKilled }
        if errno == ESRCH { return .terminated }
        if errno == EPERM { return .permissionDenied }
        return .failed("errno \(errno)")
    }

    /// Kill a batch of junk:
    /// 1. Re-sample a fresh snapshot and re-classify (TOCTOU guard).
    /// 2. Intersect with the requested pids — only what is still junk now dies.
    /// 3. Kill current-user pids directly, children before parents.
    /// 4. Send foreign-uid pids through one privileged prompt.
    static func killAll(
        requestedPids: [Int32],
        context: ClassificationContext,
        currentUID: UInt32,
        includeCaution: Bool = false
    ) async -> [KillResult] {
        let fresh = ProcessSampler.snapshot()
        let freshContext = ClassificationContext(selfPid: context.selfPid, rows: fresh)
        let stillJunk = JunkClassifier.junkRows(in: fresh, context: freshContext, includeCaution: includeCaution)
        let requested = Set(requestedPids)
        let targets = stillJunk.filter { requested.contains($0.pid) }

        // Children first so killing a parent cannot orphan kids mid-batch.
        // Closure true => lhs sorts before rhs => lhs dies first.
        // lhs dies before rhs when lhs is a descendant of rhs.
        let ordered = targets.sorted { lhs, rhs in
            isAncestor(rhs.pid, of: lhs.pid, context: freshContext)
        }

        var results: [KillResult] = []
        var rootPids: [Int32] = []

        for row in ordered {
            if JunkClassifier.needsRoot(row, currentUID: currentUID) {
                rootPids.append(row.pid)
            } else {
                let outcome = await terminate(pid: row.pid, context: freshContext)
                results.append(KillResult(pid: row.pid, name: row.name, outcome: outcome))
            }
        }

        if !rootPids.isEmpty {
            let rootResults = await PrivilegedKiller.killAsRoot(rootPids) { pid in
                freshContext.rowMap[pid].flatMap { ProcessSafety.isProtected($0, context: freshContext) } != nil
            }
            switch rootResults {
            case .success(let killed):
                let killedSet = Set(killed)
                for pid in rootPids {
                    let name = freshContext.rowMap[pid]?.name ?? String(pid)
                    if killedSet.contains(pid) {
                        // Confirm they actually died.
                        let outcome = await waitForExit(pid: pid)
                        results.append(KillResult(pid: pid, name: name, outcome: outcome))
                    }
                }
            case .failure(.userCancelled):
                for pid in rootPids {
                    let name = freshContext.rowMap[pid]?.name ?? String(pid)
                    results.append(KillResult(pid: pid, name: name, outcome: .cancelled))
                }
            case .failure(let error):
                let message = switch error {
                case .validationFailed: "validation failed"
                case .osascriptFailed(let m): m
                case .userCancelled: "cancelled"
                }
                for pid in rootPids {
                    let name = freshContext.rowMap[pid]?.name ?? String(pid)
                    results.append(KillResult(pid: pid, name: name, outcome: .failed(message)))
                }
            }
        }

        return results
    }

    /// Wait briefly for a killed pid to disappear.
    private static func waitForExit(pid: Int32, graceNanos: UInt64 = 3_000_000_000) async -> KillOutcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + graceNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return .terminated }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return kill(pid, 0) != 0 && errno == ESRCH ? .terminated : .forceKilled
    }

    private static func isAncestor(_ candidate: Int32, of pid: Int32, context: ClassificationContext) -> Bool {
        var visited = Set<Int32>()
        var current = pid
        while current > 1, !visited.contains(current) {
            visited.insert(current)
            guard let parent = context.parentMap[current] else { return false }
            if parent == candidate { return true }
            current = parent
        }
        return false
    }
}
