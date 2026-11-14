import Foundation

/// The only place `Foundation.Process` is touched. `Process`, `Pipe`, and
/// `FileHandle` are not Sendable, so everything is confined to one GCD thread
/// and only a plain tuple escapes into async-land.
///
/// Deliberately NOT `Task.detached`: the privileged prompt can block for
/// minutes, and a blocked cooperative-pool thread would starve the app.
enum ShellRunner {
    static func run(
        launchPath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                process.standardOutput = outPipe
                process.standardError = errPipe

                var timedOut = false
                let timeoutItem: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem {
                        timedOut = true
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    timeoutItem = item
                } else {
                    timeoutItem = nil
                }

                do {
                    try process.run()
                } catch {
                    timeoutItem?.cancel()
                    continuation.resume(returning: (-1, "", "launch failed: \(error.localizedDescription)"))
                    return
                }

                process.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                timeoutItem?.cancel()

                let exitCode = timedOut ? Int32(124) : process.terminationStatus
                continuation.resume(returning: (
                    exitCode,
                    String(decoding: outData, as: UTF8.self),
                    String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
