import XCTest
@testable import JMacCleaner

final class PortScannerTests: XCTestCase {
    func testParseTypicalLsofOutput() {
        let output = """
        p4201
        n*:3000
        n127.0.0.1:9229
        p85
        n*:5432
        p4201
        n[::1]:3000
        """
        let map = PortScanner.parse(output)
        XCTAssertEqual(map[4201], [3000, 9229]) // dedup + sorted
        XCTAssertEqual(map[85], [5432])
    }

    func testParseIgnoresOtherFieldsAndGarbage() {
        let output = """
        f3
        p100
        f0
        cnode
        n/tmp
        n*:0
        p
        nnocolon
        """
        let map = PortScanner.parse(output)
        // "n/tmp" has no port; "n*:0" parses as 0 which is not a valid listener
        // but is kept by the parser contract (parsing only, filtering is lsof's job).
        XCTAssertEqual(map[100], [0])
        XCTAssertNil(map[101])
    }

    func testPortExtractionForms() {
        XCTAssertEqual(PortScanner.port(from: "*:3000"), 3000)
        XCTAssertEqual(PortScanner.port(from: "127.0.0.1:5432"), 5432)
        XCTAssertEqual(PortScanner.port(from: "[::1]:3000"), 3000)
        XCTAssertEqual(PortScanner.port(from: "localhost:9229"), 9229)
        XCTAssertNil(PortScanner.port(from: "nocolon"))
        XCTAssertNil(PortScanner.port(from: "*:notanumber"))
    }

    func testEmptyOutput() {
        XCTAssertTrue(PortScanner.parse("").isEmpty)
    }
}
