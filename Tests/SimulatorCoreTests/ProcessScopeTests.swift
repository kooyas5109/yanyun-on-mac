import XCTest
@testable import SimulatorCore

final class ProcessScopeTests: XCTestCase {
    func testParserKeepsCommandWithSpaces() {
        let records = ProcessScope.parsePSOutput("""
          101     1 /bundle/wine launcher.exe
          102   101 C:\\Program Files\\FeverGames\\FeverGamesWeb.exe --type=renderer
        """)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].pid, 102)
        XCTAssertTrue(records[1].command.contains("--type=renderer"))
    }

    func testScopeIncludesDescendantsButExcludesOtherPrefix() {
        let records = [
            ProcessRecord(pid: 100, parentPID: 1, command: "/wine /Users/me/Library/Application Support/yanyun.simulator/launcher.exe"),
            ProcessRecord(pid: 101, parentPID: 100, command: "FeverGamesWeb.exe"),
            ProcessRecord(pid: 200, parentPID: 1, command: "/wine /Users/me/Library/Application Support/ywzh.simulator/launcher.exe"),
            ProcessRecord(pid: 201, parentPID: 200, command: "FeverGamesWeb.exe"),
        ]

        let matches = ProcessScope.matchingProcessIDs(
            "FeverGamesWeb",
            in: records,
            prefixPath: "/Users/me/Library/Application Support/yanyun.simulator/wine-prefix",
            appIdentifier: "yanyun.simulator",
            registeredRootPIDs: []
        )

        XCTAssertEqual(matches, [101])
    }

    func testRegisteredRootScopesChildrenWithoutPrefixInCommand() {
        let records = [
            ProcessRecord(pid: 300, parentPID: 1, command: "/bundle/wine launcher.exe"),
            ProcessRecord(pid: 301, parentPID: 300, command: "FeverGamesWeb.exe"),
        ]

        let matches = ProcessScope.matchingProcessIDs(
            "FeverGamesWeb",
            in: records,
            prefixPath: "/missing/prefix",
            appIdentifier: "missing.identifier",
            registeredRootPIDs: [300]
        )

        XCTAssertEqual(matches, [301])
    }
}
