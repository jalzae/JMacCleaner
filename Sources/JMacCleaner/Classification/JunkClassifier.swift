import Foundation

/// Allowlist-based junk classification. A process is only ever junk because a
/// positive rule matched — never because it "didn't look like system stuff".
/// That is what structurally guarantees essential apps stay out of Kill All.
enum JunkClassifier {
    /// Node/dev-server/daemon family. Kill-all eligible (tier: safe).
    static let devDaemonNames: Set<String> = [
        "node", "npm", "npx", "yarn", "pnpm", "vite", "webpack", "esbuild",
        "deno", "bun", "tsc", "rollup", "turbo", "next", "jest", "vitest",
        "nodemon", "ts-node", "tsx", "swc", "watchman", "parcel", "expo",
        "metro", "gulp", "grunt", "browserify", "terser", "postcss", "sass",
        "eslint", "prettier", "babel", "mocha", "karma", "playwright", "cypress",
    ]

    /// Background dev infrastructure that the user might actually want running.
    /// Visible as junk but excluded from Kill All unless opted in (tier: caution).
    static let backgroundDevToolNames: Set<String> = [
        "redis-server", "redis", "mongod", "postgres", "mysql", "mariadbd",
        "ngrok", "localstack", "mailpit", "mailhog", "minio", "rabbitmq-server",
        "memcached", "elasticsearch", "clickhouse-server", "clickhouse",
    ]

    /// Classify one row. Order matters: protection always wins.
    static func classify(_ row: ProcessRow, context: ClassificationContext) -> JunkVerdict {
        if let reason = ProcessSafety.isProtected(row, context: context) {
            return .protected(reason: reason)
        }

        // Orphaned Electron/Chromium helpers: dead parent or reparented to launchd.
        if isElectronHelper(row) {
            let parentAlive = context.alivePids.contains(row.ppid) && row.ppid != 1
            if !parentAlive {
                return .junk(reason: "Orphaned app helper", tier: .safe)
            }
            // Helper of a live app: neutral, even if the app is suspicious.
            return .neutral
        }

        if devDaemonNames.contains(row.classifyName) {
            return .junk(reason: "Dev daemon", tier: .safe)
        }
        if backgroundDevToolNames.contains(row.classifyName) {
            return .junk(reason: "Background dev tool", tier: .caution)
        }
        return .neutral
    }

    /// All junk rows for a snapshot: safe tier always, caution tier only if opted in.
    static func junkRows(in rows: [ProcessRow], context: ClassificationContext, includeCaution: Bool = false) -> [ProcessRow] {
        rows.filter { row in
            switch classify(row, context: context) {
            case .junk(_, let tier):
                return tier == .safe || includeCaution
            case .protected, .neutral:
                return false
            }
        }
    }

    /// True when the kill needs privileges we do not have as the current user.
    static func needsRoot(_ row: ProcessRow, currentUID: UInt32) -> Bool {
        row.uid != currentUID
    }

    /// Electron/Chromium helper signature: helper-named binary inside an app
    /// bundle's frameworks directory.
    static func isElectronHelper(_ row: ProcessRow) -> Bool {
        guard let path = row.classifyPath?.lowercased() else {
            // Path hidden (other user): fall back to name-only heuristics.
            let name = row.classifyName
            return name.contains("helper") && (name.contains("renderer") || name.contains("gpu") || name.contains("utility") || name.contains("plugin"))
        }
        let inBundle = path.contains(".app/contents/frameworks/") || path.contains(".app/contents/helpers/")
        let name = row.classifyName
        let helperNamed = name.contains("helper") || name == "renderer" || name == "gpu"
            || name.contains("utility") || name.contains("crashpad_handler")
        return inBundle && helperNamed
    }
}
