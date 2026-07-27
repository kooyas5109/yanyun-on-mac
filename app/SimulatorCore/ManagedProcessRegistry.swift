import Foundation

public struct ManagedProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let role: String
    public let launchedAt: Date
    public let sessionID: String

    public init(pid: Int32, role: String, launchedAt: Date = Date(), sessionID: String) {
        self.pid = pid
        self.role = role
        self.launchedAt = launchedAt
        self.sessionID = sessionID
    }
}

public final class ManagedProcessRegistry: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let sessionID = UUID().uuidString

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func record(pid: Int32, role: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadUnlocked()
        records.removeAll { $0.pid == pid }
        records.append(ManagedProcessRecord(pid: pid, role: role, sessionID: sessionID))
        saveUnlocked(records)
    }

    public func remove(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadUnlocked()
        records.removeAll { $0.pid == pid }
        saveUnlocked(records)
    }

    @discardableResult
    public func activePIDs(isAlive: (Int32) -> Bool) -> Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        let active = loadUnlocked().filter {
            $0.sessionID == sessionID && isAlive($0.pid)
        }
        saveUnlocked(active)
        return Set(active.map(\.pid))
    }

    public func records() -> [ManagedProcessRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [ManagedProcessRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([ManagedProcessRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func saveUnlocked(_ records: [ManagedProcessRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
