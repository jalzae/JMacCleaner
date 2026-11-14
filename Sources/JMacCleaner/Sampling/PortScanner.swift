import Foundation

/// Maps pid -> listening TCP ports by parsing `lsof -Fp -Fn` field output.
/// lsof reports socket owners via the kernel PCB tables, so listening ports of
/// other users (postgres on 5432, a root web server on 80…) show up too.
enum PortScanner {
    static func listeningByPid() async -> [Int32: [UInt16]] {
        let result = await ShellRunner.run(
            launchPath: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fp", "-Fn"],
            timeout: 5
        )
        // lsof exits 1 when it finds nothing — not an error for us.
        guard result.exitCode == 0 || result.exitCode == 1 else { return [:] }
        return Self.parse(result.stdout)
    }

    /// Pure parser — unit-tested.
    static func parse(_ output: String) -> [Int32: [UInt16]] {
        var map: [Int32: [UInt16]] = [:]
        var currentPid: Int32?

        for line in output.split(separator: "\n") {
            guard let tag = line.first, line.count > 1 else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                currentPid = Int32(value)
            case "n":
                guard let pid = currentPid, let port = Self.port(from: String(value)) else { continue }
                map[pid, default: []].append(port)
            default:
                break
            }
        }
        return map.mapValues { Array(Set($0)).sorted() }
    }

    /// Extracts the port from a NAME field: `*:3000`, `127.0.0.1:5432`,
    /// `[::1]:3000`, `localhost:9229`.
    static func port(from name: String) -> UInt16? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let tail = name[name.index(after: colon)...]
        return UInt16(tail)
    }
}
