import XCTest
@testable import SimulatorCore

final class ManagedProcessRegistryTests: XCTestCase {
    func testRegistryPrunesStaleProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let registry = ManagedProcessRegistry(fileURL: directory.appendingPathComponent("processes.json"))
        registry.record(pid: 11, role: "launcher")
        registry.record(pid: 12, role: "wineserver")

        let active = registry.activePIDs { $0 == 12 }

        XCTAssertEqual(active, [12])
        XCTAssertEqual(registry.records().map(\.pid), [12])
    }

    func testNewSessionDoesNotTrustPersistedPIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("processes.json")
        ManagedProcessRegistry(fileURL: file).record(pid: 42, role: "launcher")

        let restartedRegistry = ManagedProcessRegistry(fileURL: file)
        XCTAssertTrue(restartedRegistry.activePIDs { _ in true }.isEmpty)
    }
}
