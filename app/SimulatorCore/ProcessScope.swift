import Foundation

public struct ProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let command: String

    public init(pid: Int32, parentPID: Int32, command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
    }
}

public enum ProcessScope {
    public static func parsePSOutput(_ output: String) -> [ProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]) else {
                return nil
            }
            return ProcessRecord(pid: pid, parentPID: parentPID, command: String(fields[2]))
        }
    }

    public static func scopedProcessIDs(
        in records: [ProcessRecord],
        prefixPath: String,
        appIdentifier: String,
        registeredRootPIDs: Set<Int32>
    ) -> Set<Int32> {
        var scoped = registeredRootPIDs
        for record in records {
            if record.command.contains(prefixPath) || record.command.contains(appIdentifier) {
                scoped.insert(record.pid)
            }
        }

        var changed = true
        while changed {
            changed = false
            for record in records where scoped.contains(record.parentPID) && !scoped.contains(record.pid) {
                scoped.insert(record.pid)
                changed = true
            }
        }
        return scoped
    }

    public static func matchingProcessIDs(
        _ processName: String,
        in records: [ProcessRecord],
        prefixPath: String,
        appIdentifier: String,
        registeredRootPIDs: Set<Int32>
    ) -> Set<Int32> {
        let scoped = scopedProcessIDs(
            in: records,
            prefixPath: prefixPath,
            appIdentifier: appIdentifier,
            registeredRootPIDs: registeredRootPIDs
        )
        let needle = processName.lowercased()
        return Set(records.lazy.filter {
            scoped.contains($0.pid) && $0.command.lowercased().contains(needle)
        }.map(\.pid))
    }
}
