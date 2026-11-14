import XCTest
@testable import JMacCleaner

final class SafetyRulesTests: XCTestCase {
    private func context(_ rows: [ProcessRow], selfPid: Int32 = 99) -> ClassificationContext {
        ClassificationContext(selfPid: selfPid, rows: rows)
    }

    private func assertProtected(_ reason: ProtectionReason?, equals expected: ProtectionReason,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reason, expected, file: file, line: line)
    }

    func testEverySystemNameEntryIsProtectedByName() {
        for name in ProcessSafety.systemNames {
            let row = makeRow(pid: 200, ppid: 1, name: name, path: "/somewhere/else/\(name)")
            let ctx = context([row])
            assertProtected(ProcessSafety.isProtected(row, context: ctx), equals: .essentialSystem)
        }
    }

    func testSystemPathsProtected() {
        // Basenames deliberately avoid systemNames so the path rule is what fires.
        let prefixes = [
            ("/System/Library/SomeDaemon", "somedaeom"),
            ("/usr/libexec/trustedpeersd", "trustedpeersd"),
            ("/usr/sbin/mysteryhelper", "mysteryhelper"),
            ("/sbin/wrappertest", "wrappertest"),
            ("/Library/Apple/StagedThing", "stagedthing"),
        ]
        for (path, name) in prefixes {
            let row = makeRow(pid: 201, ppid: 1, name: name, path: path)
            let ctx = context([row])
            assertProtected(ProcessSafety.isProtected(row, context: ctx), equals: .systemPath)
        }
    }

    func testAppPidProtected() {
        let app = makeRow(pid: 99, ppid: 1, name: "JMacCleaner", path: "/Users/me/dev/JMacCleaner/build/JMacCleaner.app/Contents/MacOS/JMacCleaner")
        let ctx = context([app], selfPid: 99)
        assertProtected(ProcessSafety.isProtected(app, context: ctx), equals: .selfOrAncestor)
    }

    func testZombieProtected() {
        let zombie = makeRow(pid: 210, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", isZombie: true)
        let ctx = context([zombie])
        assertProtected(ProcessSafety.isProtected(zombie, context: ctx), equals: .zombie)
    }

    func testShellAndTerminalProtectedByName() {
        for name in ["zsh", "bash", "ssh", "tmux"] {
            let row = makeRow(pid: 220, ppid: 1, name: name, path: "/bin/\(name)")
            let ctx = context([row])
            assertProtected(ProcessSafety.isProtected(row, context: ctx), equals: .sessionHost)
        }
    }

    func testFinderProtectedBySystemName() {
        let finder = makeRow(pid: 230, ppid: 1, name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        let ctx = context([finder])
        assertProtected(ProcessSafety.isProtected(finder, context: ctx), equals: .essentialSystem)
    }

    func testPathBasenameInSystemNamesBeatsPathRule() {
        // Spotlight's basename is in systemNames, so that reason wins over systemPath.
        let spotlight = makeRow(pid: 231, ppid: 1, name: "SpotlightX", path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight")
        let ctx = context([spotlight])
        assertProtected(ProcessSafety.isProtected(spotlight, context: ctx), equals: .essentialSystem)
    }

    func testAncestorChainWalksToLaunchdAndStops() {
        let a = makeRow(pid: 240, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let b = makeRow(pid: 241, ppid: 240, name: "zsh", path: "/bin/zsh")
        let c = makeRow(pid: 242, ppid: 241, name: "node", path: "/opt/homebrew/bin/node")
        let ctx = context([a, b, c])
        let chain = ProcessSafety.ancestorNames(of: 242, context: ctx)
        XCTAssertEqual(chain.map(\.pid), [242, 241, 240])
    }

    func testAncestorChainHandlesCycle() {
        let x = makeRow(pid: 250, ppid: 251, name: "a", path: "/tmp/a")
        let y = makeRow(pid: 251, ppid: 250, name: "b", path: "/tmp/b")
        let ctx = context([x, y])
        let chain = ProcessSafety.ancestorNames(of: 250, context: ctx)
        XCTAssertLessThanOrEqual(chain.count, 2)
    }
}
