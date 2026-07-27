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

    func testRuntimePathScopesReparentedWineProcessAfterLauncherExits() {
        let records = [
            ProcessRecord(
                pid: 401,
                parentPID: 1,
                command: "FeverGamesWeb.exe --type=renderer",
                executablePath: "/candidate/wine-release/lib/wine/x86_64-unix/wine"
            ),
            ProcessRecord(
                pid: 501,
                parentPID: 1,
                command: "FeverGamesWeb.exe --type=renderer",
                executablePath: "/other/wine-release/lib/wine/x86_64-unix/wine"
            ),
            ProcessRecord(
                pid: 601,
                parentPID: 1,
                command: "FeverGamesWeb.exe --type=renderer",
                executablePath: "/candidate/wine-release-copy/lib/wine/x86_64-unix/wine"
            ),
        ]

        let matches = ProcessScope.matchingProcessIDs(
            "FeverGamesWeb",
            in: records,
            prefixPath: "/missing/prefix",
            appIdentifier: "missing.identifier",
            runtimePath: "/candidate/wine-release",
            registeredRootPIDs: []
        )

        XCTAssertEqual(matches, [401])
    }

    func testOpenFilePathsValidateExactWinePrefix() {
        let currentPrefix = "/Users/me/Library/Application Support/ywzh.simulator/wine-prefix"
        let currentOutput = """
        p19351
        fcwd
        n\(currentPrefix)/drive_c/Program Files/FeverGames
        ftxt
        n\(currentPrefix)/drive_c/Program Files/FeverGames/1.18.41.2/icudtl.dat
        """
        let otherOutput = """
        p29351
        fcwd
        n/Users/me/Library/Application Support/yanyun.simulator/wine-prefix/drive_c
        """
        let similarOutput = """
        p39351
        fcwd
        n\(currentPrefix)-copy/drive_c
        """

        XCTAssertTrue(ProcessScope.openFiles(currentOutput, usePrefix: currentPrefix))
        XCTAssertFalse(ProcessScope.openFiles(otherOutput, usePrefix: currentPrefix))
        XCTAssertFalse(ProcessScope.openFiles(similarOutput, usePrefix: currentPrefix))
    }
}
