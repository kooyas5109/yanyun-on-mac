import XCTest
@testable import SimulatorCore

final class RuntimeIntegrityTests: XCTestCase {
    func testSHA256() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)

        XCTAssertEqual(
            RuntimeIntegrity.sha256(ofFile: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDiagnosticRedactionAndCrashFiltering() {
        XCTAssertEqual(
            DiagnosticRedactor.redact("/Users/test/Library/Logs", homeDirectory: "/Users/test"),
            "~/Library/Logs"
        )
        XCTAssertEqual(
            DiagnosticRedactor.redact(
                "download=https://example.invalid/file?token=secret",
                homeDirectory: ""
            ),
            "download=https://example.invalid/file?<redacted>"
        )
        XCTAssertEqual(
            DiagnosticRedactor.redact(
                #"{"access_token":"secret-value"}"#,
                homeDirectory: ""
            ),
            #"{"access_token":"<redacted>"}"#
        )
        XCTAssertTrue(DiagnosticRedactor.isRelevantCrashReport("FeverGamesWeb-2026-07-27.ips"))
        XCTAssertFalse(DiagnosticRedactor.isRelevantCrashReport("Safari-2026-07-27.ips"))
    }
}
