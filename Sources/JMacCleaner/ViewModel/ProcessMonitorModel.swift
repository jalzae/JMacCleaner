import Foundation
import SwiftUI

/// Central UI state: the process list, filters, and all kill flows.
@MainActor
@Observable
final class ProcessMonitorModel {
    // MARK: - State

    private(set) var rows: [ProcessRow] = []
    private(set) var verdicts: [Int32: JunkVerdict] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var isPaused = false
    private(set) var killInProgress = false
    private(set) var killReport: [KillResult]?
    private(set) var toast: Toast?

    var searchText = ""
    var junkOnly = false
    var includeCaution = false
    var sortOrder: [KeyPathComparator<ProcessRow>] = []
    var refreshInterval: TimeInterval = 2.0
    var pendingKill: ProcessRow?
    var pendingRootKill: ProcessRow?
    var showKillAllSheet = false

    struct Toast: Identifiable, Equatable {
        enum Kind: Equatable { case info, success, warning, error }
        let id = UUID()
        let kind: Kind
        let message: String
    }

    // MARK: - Derived

    let selfPid = ProcessInfo.processInfo.processIdentifier
    private let currentUID = getuid()
    private var refreshTask: Task<Void, Never>?
    private var cpuTracker = CpuRateTracker()

    var visibleRows: [ProcessRow] {
        var result = rows
        if junkOnly {
            result = result.filter { isJunk($0) }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query)
                    || ($0.path?.lowercased().contains(query) ?? false)
                    || String($0.pid).contains(query)
                    || $0.ports.contains { String($0).contains(query) }
            }
        }
        if !sortOrder.isEmpty {
            result = result.sorted(using: sortOrder)
        }
        return result
    }

    var junkRows: [ProcessRow] {
        JunkClassifier.junkRows(in: rows, context: context, includeCaution: includeCaution)
    }

    var rootJunkCount: Int {
        junkRows.filter { $0.uid != currentUID }.count
    }

    var context: ClassificationContext {
        ClassificationContext(selfPid: selfPid, rows: rows)
    }

    var sortedJunkSummary: String {
        let junk = junkRows
        let roots = rootJunkCount
        if junk.isEmpty { return "No junk processes found." }
        return roots > 0
            ? "\(junk.count) junk process\(junk.count == 1 ? "" : "es") (\(roots) need administrator)."
            : "\(junk.count) junk process\(junk.count == 1 ? "" : "es")."
    }

    // MARK: - Lifecycle

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !self.isPaused {
                    await self.refreshOnce()
                    let interval = self.refreshInterval
                    try? await Task.sleep(for: .seconds(interval))
                } else {
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Refresh

    func refreshOnce() async {
        guard !killInProgress else { return }
        isRefreshing = true
        // Blocking snapshot off the main thread; only assignment lands here.
        // lsof (ports) runs concurrently with the sysctl/libproc snapshot.
        async let portTask = PortScanner.listeningByPid()
        var fresh = await Task.detached(priority: .userInitiated) {
            ProcessSampler.snapshot()
        }.value
        let portMap = await portTask
        if !portMap.isEmpty {
            for index in fresh.indices {
                if let ports = portMap[fresh[index].pid] {
                    fresh[index].ports = ports
                }
            }
        }

        cpuTracker.annotate(&fresh)
        cpuTracker.prune(alivePids: Set(fresh.map(\.pid)))

        rows = fresh
        lastUpdated = Date()

        var map: [Int32: JunkVerdict] = [:]
        let ctx = ClassificationContext(selfPid: selfPid, rows: fresh)
        for row in fresh { map[row.pid] = JunkClassifier.classify(row, context: ctx) }
        verdicts = map
        isRefreshing = false
    }

    // MARK: - Verdict helpers

    func verdict(for row: ProcessRow) -> JunkVerdict? {
        verdicts[row.pid]
    }

    func isJunk(_ row: ProcessRow) -> Bool {
        switch verdicts[row.pid] {
        case .junk(_, .safe): return true
        case .junk(_, .caution): return includeCaution
        default: return false
        }
    }

    func isProtected(_ row: ProcessRow) -> Bool {
        guard let verdict = verdicts[row.pid] else { return false }
        if case .protected = verdict { return true }
        return false
    }

    func protectionReason(_ row: ProcessRow) -> String? {
        guard let verdict = verdicts[row.pid], case .protected(let reason) = verdict else { return nil }
        return reason.description
    }

    func junkReason(_ row: ProcessRow) -> String? {
        guard let verdict = verdicts[row.pid], case .junk(let reason, _) = verdict else { return nil }
        return reason
    }

    func junkTier(_ row: ProcessRow) -> JunkTier? {
        guard let verdict = verdicts[row.pid], case .junk(_, let tier) = verdict else { return nil }
        return tier
    }

    func needsRoot(_ row: ProcessRow) -> Bool {
        row.uid != currentUID
    }

    // MARK: - Kill flows

    func beginKill(_ row: ProcessRow) {
        guard !killInProgress else { return }
        if isProtected(row) { return }
        if needsRoot(row) {
            pendingRootKill = row
        } else {
            pendingKill = row
        }
    }

    /// Confirm the normal single kill (same user).
    func confirmKill(_ row: ProcessRow) async {
        pendingKill = nil
        guard !killInProgress else { return }
        killInProgress = true
        defer { killInProgress = false }

        let ctx = context
        let outcome = await ProcessKiller.terminate(pid: row.pid, context: ctx)
        showToast(from: outcome, name: row.name, pid: row.pid)
        await refreshOnce()
    }

    /// Confirm the root single kill — triggers the native password prompt.
    func confirmRootKill(_ row: ProcessRow) async {
        pendingRootKill = nil
        guard !killInProgress else { return }
        killInProgress = true
        defer { killInProgress = false }

        let ctx = context
        let result = await PrivilegedKiller.killAsRoot([row.pid]) { pid in
            ctx.rowMap[pid].flatMap { ProcessSafety.isProtected($0, context: ctx) } != nil
        }
        switch result {
        case .success:
            showToast(.success, "\(row.name) (\(row.pid)) stopped with administrator privileges")
        case .failure(.userCancelled):
            showToast(.info, "Administrator prompt cancelled — \(row.name) still running")
        case .failure(let error):
            showToast(.error, "Root kill failed: \(String(describing: error))")
        }
        await refreshOnce()
    }

    /// Kill All Junk: confirm sheet -> orchestrated batch with one admin prompt max.
    func confirmKillAll() async {
        showKillAllSheet = false
        guard !killInProgress else { return }
        killInProgress = true
        defer { killInProgress = false }

        let ctx = context
        let pids = junkRows.map(\.pid)
        guard !pids.isEmpty else {
            showToast(.info, "Nothing to kill.")
            return
        }
        killReport = await ProcessKiller.killAll(
            requestedPids: pids,
            context: ctx,
            currentUID: currentUID,
            includeCaution: includeCaution
        )
        await refreshOnce()
    }

    func dismissKillReport() {
        killReport = nil
    }

    func togglePause() {
        isPaused.toggle()
    }

    // MARK: - Toasts

    private func showToast(_ kind: Toast.Kind, _ message: String) {
        toast = Toast(kind: kind, message: message)
        let id = toast?.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if let self, let current = self.toast, current.id == id {
                self.toast = nil
            }
        }
    }

    private func showToast(from outcome: KillOutcome, name: String, pid: Int32) {
        switch outcome {
        case .terminated: showToast(.success, "\(name) (\(pid)) terminated")
        case .forceKilled: showToast(.success, "\(name) (\(pid)) force killed")
        case .alreadyGone: showToast(.info, "\(name) (\(pid)) was already gone")
        case .permissionDenied: showToast(.warning, "\(name) (\(pid)) needs administrator")
        case .cancelled: showToast(.info, "Cancelled")
        case .failed(let message): showToast(.error, "\(name) (\(pid)): \(message)")
        }
    }
}
