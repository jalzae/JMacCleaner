import Foundation
import Darwin

/// Enumerates every process on the system via libproc + sysctl. Blocking and
/// nonisolated — always call from a background task.
enum ProcessSampler {
    /// Full snapshot of all processes (excluding pid 0 and ones that die mid-scan).
    static func snapshot() -> [ProcessRow] {
        let procs = allKinfoProcs()
        var rows: [ProcessRow] = []
        rows.reserveCapacity(procs.count)
        var uidNames = UIDNameCache()

        for kp in procs {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }

            let startSeconds = Double(kp.kp_proc.p_starttime.tv_sec)
                + Double(kp.kp_proc.p_starttime.tv_usec) / 1_000_000.0
            let uid = kp.kp_eproc.e_pcred.p_ruid
            // p_comm is a fixed-size C char tuple; read via raw memory.
            let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
            let path = executablePath(for: pid)
            let name = path.map { ($0 as NSString).lastPathComponent } ?? comm

            guard let usage = rusage(for: pid) else { continue } // died mid-scan

            let isZombie = kp.kp_proc.p_stat == SZOMB

            rows.append(ProcessRow(
                pid: pid,
                ppid: kp.kp_eproc.e_ppid,
                name: name,
                path: path,
                uid: uid,
                uidName: uidNames.name(for: uid),
                cpuPercent: 0,
                ports: [],
                residentBytes: usage.residentBytes,
                isZombie: isZombie,
                startSeconds: startSeconds
            ))
        }
        return rows
    }

    // MARK: - sysctl KERN_PROC_ALL

    private static func allKinfoProcs() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        for _ in 0..<2 {
            // Grow generously — the table can grow between size query and copy.
            let padded = (size / MemoryLayout<kinfo_proc>.stride) + 64
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: padded)
            var actual = padded * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 3, &procs, &actual, nil, 0) == 0 {
                let count = actual / MemoryLayout<kinfo_proc>.stride
                return Array(procs[0..<max(0, count)])
            }
            size = actual * 2
        }
        return []
    }

    // MARK: - per-pid details

    private static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func rusage(for pid: Int32) -> (cpuMicros: UInt64, residentBytes: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutableBytes(of: &info) { raw -> Int32 in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard rc == 0 else { return nil }
        return (info.ri_user_time &+ info.ri_system_time, info.ri_resident_size)
    }
}

/// Memoizes uid -> username per sampling tick so `getpwuid` is not hammered
/// once per process.
struct UIDNameCache {
    private var names: [UInt32: String] = [:]

    mutating func name(for uid: UInt32) -> String {
        if let cached = names[uid] { return cached }
        let resolved = Self.resolve(uid)
        names[uid] = resolved
        return resolved
    }

    static func resolve(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid_t(uid)), let name = pw.pointee.pw_name else {
            return String(uid)
        }
        return String(cString: name)
    }
}
