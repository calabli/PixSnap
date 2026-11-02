import Foundation

/// A version like "0.3.1", compared number by number ("0.10.0" is after "0.9.2").
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// Accepts a leading "v" ("v0.3.1"); nil when it isn't numbers separated by dots.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0 ..< max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// What a release says about itself: `latest.json`, published with every release next to the
/// installer, which installed copies read to find out about updates.
public struct UpdateInfo: Codable, Equatable, Sendable {
    public var version: String
    /// What's new, in Markdown (headings and bold, one item per line).
    public var notes: String
    /// The installer package.
    public var url: URL
    public var sha256: String
    public var size: Int
    public var minimumSystemVersion: String

    public init(version: String, notes: String, url: URL, sha256: String, size: Int, minimumSystemVersion: String) {
        self.version = version
        self.notes = notes
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// Whether this release is newer than `current`, and runs on `system` ("14.6.1").
    public func isUpdate(over current: String, system: String) -> Bool {
        guard let mine = AppVersion(current), let theirs = AppVersion(version), theirs > mine else { return false }
        guard let needed = AppVersion(minimumSystemVersion), let running = AppVersion(system) else { return true }
        return running >= needed
    }
}
