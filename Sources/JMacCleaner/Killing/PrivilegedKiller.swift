import Foundation

enum PrivilegedKillError: Error, Sendable, Equatable {
    case userCancelled
    case validationFailed
    case osascriptFailed(String)
}

/// Kills processes owned by other users (usually root) by shelling out to
/// `osascript ... with administrator privileges`. That shows the native macOS
/// password prompt. The app itself never runs as root, and only integers are
/// ever interpolated into the script — no process-supplied strings.
enum PrivilegedKiller {
    static func killAsRoot(_ pids: [Int32], protectedCheck: (@Sendable (Int32) -> Bool)? = nil) async -> Result<[Int32], PrivilegedKillError> {
        let valid = pids.filter { $0 > 1 }
        guard !valid.isEmpty else { return .failure(.validationFailed) }
        if let protectedCheck, valid.contains(where: protectedCheck) {
            return .failure(.validationFailed)
        }

        let pidList = valid.map(String.init).joined(separator: " ")
        let script = "do shell script \"kill -TERM \(pidList)\" with administrator privileges"

        let result = await ShellRunner.run(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 300 // password prompt can legitimately sit for a while
        )

        if result.exitCode == 0 {
            return .success(valid)
        }
        if result.exitCode == -128 || result.stderr.contains("User canceled") {
            return .failure(.userCancelled)
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(.osascriptFailed(message.isEmpty ? "osascript exited \(result.exitCode)" : message))
    }
}
