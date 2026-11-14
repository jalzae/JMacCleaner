import XCTest
@testable import JMacCleaner

/// Synthetic row factory for classifier tests.
func makeRow(
    pid: Int32,
    ppid: Int32 = 1,
    name: String,
    path: String? = nil,
    uid: UInt32 = 501,
    isZombie: Bool = false
) -> ProcessRow {
    ProcessRow(
        pid: pid,
        ppid: ppid,
        name: path.map { ($0 as NSString).lastPathComponent } ?? name,
        path: path,
        uid: uid,
        uidName: uid == 0 ? "root" : "me",
        cpuPercent: 0,
        ports: [],
        residentBytes: 10_000_000,
        isZombie: isZombie,
        startSeconds: 1_000_000 + Double(pid)
    )
}

final class JunkClassifierTests: XCTestCase {
    private func context(_ rows: [ProcessRow], selfPid: Int32 = 99) -> ClassificationContext {
        ClassificationContext(selfPid: selfPid, rows: rows)
    }

    func testDevDaemonIsJunk() {
        let node = makeRow(pid: 100, ppid: 1, name: "node", path: "/opt/homebrew/bin/node")
        let ctx = context([node])
        XCTAssertEqual(JunkClassifier.classify(node, context: ctx), .junk(reason: "Dev daemon", tier: .safe))
    }

    func testOrphanedElectronHelperIsJunk() {
        let helper = makeRow(
            pid: 101, ppid: 1,
            name: "Slack Helper (Renderer)",
            path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
        )
        let ctx = context([helper])
        XCTAssertEqual(JunkClassifier.classify(helper, context: ctx), .junk(reason: "Orphaned app helper", tier: .safe))
    }

    func testLiveElectronHelperIsNeutral() {
        let slack = makeRow(pid: 102, ppid: 1, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack")
        let helper = makeRow(pid: 103, ppid: 102, name: "Slack Helper (Renderer)", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)")
        let ctx = context([slack, helper])
        XCTAssertEqual(JunkClassifier.classify(helper, context: ctx), .neutral)
    }

    func testBackgroundDevToolIsCautionTier() {
        let redis = makeRow(pid: 104, ppid: 1, name: "redis-server", path: "/opt/homebrew/bin/redis-server")
        let ctx = context([redis])
        XCTAssertEqual(JunkClassifier.classify(redis, context: ctx), .junk(reason: "Background dev tool", tier: .caution))
    }

    func testCautionTierExcludedFromKillAllByDefault() {
        let node = makeRow(pid: 105, ppid: 1, name: "node", path: "/opt/homebrew/bin/node")
        let redis = makeRow(pid: 106, ppid: 1, name: "redis-server", path: "/opt/homebrew/bin/redis-server")
        let ctx = context([node, redis])
        let junk = JunkClassifier.junkRows(in: [node, redis], context: ctx, includeCaution: false)
        XCTAssertEqual(junk.map(\.pid), [105])
        let withCaution = JunkClassifier.junkRows(in: [node, redis], context: ctx, includeCaution: true)
        XCTAssertEqual(Set(withCaution.map(\.pid)), [105, 106])
    }

    func testClaudeInsideTerminalIsProtected() {
        // Simulate: Terminal -> zsh -> node (claude) -> node (claude child).
        let terminal = makeRow(pid: 110, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let zsh = makeRow(pid: 111, ppid: 110, name: "zsh", path: "/bin/zsh")
        let claude = makeRow(pid: 112, ppid: 111, name: "node", path: "/Users/me/.claude/local/node_modules/.bin/node")
        let child = makeRow(pid: 113, ppid: 112, name: "node", path: "/opt/homebrew/bin/node")
        let ctx = context([terminal, zsh, claude, child])

        XCTAssertEqual(JunkClassifier.classify(claude, context: ctx), .protected(reason: .sessionHost))
        XCTAssertEqual(JunkClassifier.classify(child, context: ctx), .protected(reason: .sessionHost))
    }

    func testOrphanNodeWithLaunchdParentIsJunk() {
        // node whose parent is launchd (1) and no session host anywhere.
        let orphan = makeRow(pid: 120, ppid: 1, name: "node", path: "/opt/homebrew/bin/node")
        let ctx = context([orphan])
        XCTAssertEqual(JunkClassifier.classify(orphan, context: ctx), .junk(reason: "Dev daemon", tier: .safe))
    }

    func testRegularAppIsNeutral() {
        let safari = makeRow(pid: 130, ppid: 1, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")
        let ctx = context([safari])
        XCTAssertEqual(JunkClassifier.classify(safari, context: ctx), .neutral)
    }

    func testNeedsRoot() {
        let mine = makeRow(pid: 140, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", uid: 501)
        let root = makeRow(pid: 141, ppid: 1, name: "node", path: "/opt/homebrew/bin/node", uid: 0)
        XCTAssertTrue(JunkClassifier.needsRoot(root, currentUID: 501))
        XCTAssertFalse(JunkClassifier.needsRoot(mine, currentUID: 501))
    }
}
