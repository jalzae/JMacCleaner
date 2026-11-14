import Foundation

/// Hard guardrails evaluated before every kill. A process matching ANY rule is
/// untouchable — even in root mode.
enum ProcessSafety {
    /// Kernel, window server, and core session services. Killing these breaks
    /// the login session or the machine.
    static let systemNames: Set<String> = [
        "launchd", "kernel_task", "loginwindow", "windowserver", "finder",
        "dock", "systemuiserver", "controlcenter", "spotlight", "spotlightui",
        "coreservicesd", "coreaudiod", "securityd", "configd", "mdnsresponder",
        "opendirectoryd", "syslogd", "powerd", "hidd", "bluetoothd",
        "usereventagent", "distnoted", "tccd", "cfprefsd", "dock_tile",
        "notificationcenter", "sharingd", "identityservicesd", "imeservice",
        "bird", "clouddocs", "fileproviderd", "truncate", "backgroundtaskmanagementagent",
        "coreserviceuiagent", "paged", "symptomsd", "nehelper", "nesessionmanager",
        "networkserviceproxy", "nsurlsessiond", "apsd", "mediaremoted",
        "audiocoreservice", "core brightness d", "hpacketsender", "wirelessradiorespmanagerd",
    ]

    /// Signed system install locations. Anything launching from here is off-limits.
    static let systemPathPrefixes: [String] = [
        "/system/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/",
        "/library/apple/", "/private/var/db/", "/usr/lib/",
    ]

    /// Terminal and editor apps hosting the user's session — killing them (or
    /// anything descended from them) can end this very session, including
    /// Claude Code running inside it.
    static let sessionHostNames: Set<String> = [
        "terminal", "iterm2", "warp", "alacritty", "kitty", "ghostty",
        "wezterm", "hyper", "ssh", "zsh", "bash", "fish", "sh", "tmux",
        "screen", "claude", "codex", "gemini", "cursor", "code", "electron",
        "visual studio code", "visualstudiocode", "windsurf", "zed", "sublime_text",
        "ruby-mri", "python3", "python", "pwsh", "nushell", "elvish", "xonsh",
    ]

    /// Path fragments identifying a session host regardless of process name.
    static let sessionHostPathFragments: [String] = [
        "/terminal.app/", "/iterm.app/", "/iterm2.app/", "/warp.app/",
        "/alacritty.app/", "/kitty.app/", "/ghostty.app/", "/wezterm.app/",
        "/visual studio code.app/", "/vscodium.app/", "/cursor.app/",
        "/zed.app/", "/windsurf.app/", "/sublime text.app/", "/hyper.app/",
        "/.claude/", "/claude-code/", "/claude code/",
    ]

    /// Returns why this process must not be killed, or nil if it is fair game.
    static func isProtected(
        _ row: ProcessRow,
        context: ClassificationContext
    ) -> ProtectionReason? {
        if row.isZombie { return .zombie }
        if row.pid == context.selfPid { return .selfOrAncestor }

        let chain = ancestorNames(of: row.pid, context: context)
        // The chain includes the process itself first.
        if let own = chain.first {
            let ownName = own.name.lowercased()
            if ownName.hasPrefix("claude") || ownName.contains("claude") {
                return .selfOrAncestor
            }
        }

        // Any ancestor (including itself) that is a session host protects the process.
        for entry in chain {
            let name = entry.name.lowercased()
            if sessionHostNames.contains(name) { return .sessionHost }
            if let path = entry.path?.lowercased() {
                if sessionHostPathFragments.contains(where: { path.contains($0) }) {
                    return .sessionHost
                }
            }
        }

        let selfName = row.classifyName
        if systemNames.contains(selfName) { return .essentialSystem }
        if let path = row.classifyPath?.lowercased() {
            if systemPathPrefixes.contains(where: { path.hasPrefix($0) }) { return .systemPath }
            if sessionHostPathFragments.contains(where: { path.contains($0) }) { return .sessionHost }
        }
        return nil
    }

    /// Walk from `pid` up to launchd. Returns (pid, name, path) entries starting
    /// with `pid` itself. Guards against cycles and missing parents.
    static func ancestorNames(
        of pid: Int32,
        context: ClassificationContext
    ) -> [(pid: Int32, name: String, path: String?)] {
        var chain: [(pid: Int32, name: String, path: String?)] = []
        var visited = Set<Int32>()
        var current = pid
        let map = context.rowMap

        while current > 1, !visited.contains(current) {
            visited.insert(current)
            guard let row = map[current] else { break }
            chain.append((row.pid, row.name, row.path))
            current = row.ppid
        }
        return chain
    }
}
