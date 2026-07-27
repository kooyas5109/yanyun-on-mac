import CryptoKit
import Foundation

public enum RuntimeIntegrity {
    public static func sha256(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DiagnosticRedactor {
    public static func redact(_ text: String, homeDirectory: String) -> String {
        var redacted = homeDirectory.isEmpty
            ? text
            : text.replacingOccurrences(of: homeDirectory, with: "~")
        let rules: [(String, String)] = [
            (#"(?i)(https?://[^\s?]+)\?[^\s"']+"#, "$1?<redacted>"),
            (#"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)("(?:access_?token|refresh_?token|password|secret|cookie)"\s*:\s*")[^"]*"#, "$1<redacted>"),
        ]
        for (pattern, replacement) in rules {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return redacted
    }

    public static func isRelevantCrashReport(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return [
            "simulator",
            "fevergames",
            "yysls",
            "ywzh",
            "wine",
            "wineserver",
        ].contains { lower.contains($0) }
    }
}
