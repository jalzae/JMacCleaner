import Foundation

enum JunkTier: Sendable, Equatable {
    /// Safe to include in "Kill All Junk".
    case safe
    /// Background dev tool that may matter (database, tunnel...). Excluded from
    /// Kill All unless the user opts in.
    case caution
}

enum ProtectionReason: Sendable, Equatable {
    case selfOrAncestor
    case essentialSystem
    case systemPath
    case sessionHost
    case zombie

    var description: String {
        switch self {
        case .selfOrAncestor: return "This app or its parent"
        case .essentialSystem: return "Essential macOS process"
        case .systemPath: return "Signed system path"
        case .sessionHost: return "Terminal/editor session host"
        case .zombie: return "Zombie (waiting to be reaped)"
        }
    }
}

enum JunkVerdict: Sendable, Equatable {
    case junk(reason: String, tier: JunkTier)
    case protected(reason: ProtectionReason)
    case neutral
}

/// Everything the classifier needs beyond a single row.
struct ClassificationContext: Sendable {
    let selfPid: Int32
    let alivePids: Set<Int32>
    /// pid -> parent pid for the current snapshot.
    let parentMap: [Int32: Int32]
    /// pid -> row for the current snapshot (ancestor walks, orphan detection).
    let rowMap: [Int32: ProcessRow]

    init(selfPid: Int32, rows: [ProcessRow]) {
        self.selfPid = selfPid
        self.alivePids = Set(rows.map(\.pid))
        var parents: [Int32: Int32] = [:]
        var rowsMap: [Int32: ProcessRow] = [:]
        for row in rows where row.pid > 0 {
            parents[row.pid] = row.ppid
            rowsMap[row.pid] = row
        }
        self.parentMap = parents
        self.rowMap = rowsMap
    }
}
