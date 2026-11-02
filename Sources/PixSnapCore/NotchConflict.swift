import Foundation

/// Other apps that live in the notch (NotchNook and the like): they also react when the mouse
/// goes to the notch or pulls down from it, so they and the clothesline can get in each other's way.
public enum NotchConflict {
    public struct App: Sendable {
        public let name: String
        public let bundleIDs: [String]
    }

    public static let knownApps: [App] = [
        App(name: "NotchNook", bundleIDs: ["lo.cafe.NotchNook"]),
        App(name: "Boring Notch", bundleIDs: ["theboringteam.boringnotch", "com.theboringteam.boringnotch"]),
        App(name: "Alcove", bundleIDs: ["com.henrikruscon.Alcove"]),
        App(name: "DynamicLake", bundleIDs: ["com.aviorrok.DynamicLakePro", "com.aviorrok.DynamicLake"]),
        App(name: "MediaMate", bundleIDs: ["com.tweety.MediaMate"]),
        App(name: "NotchDrop", bundleIDs: ["wiki.qaq.NotchDrop"]),
        App(name: "Mew Notch", bundleIDs: ["com.monuk7735.mew-notch"]),
        App(name: "TopNotch", bundleIDs: ["pl.maketheweb.TopNotch"]),
    ]

    /// The names of the notch apps among `running` (bundle id and name of each running app): the
    /// known ones by bundle id or name, and any other whose name has "notch" in it. PixSnap
    /// itself, and TopNotch (which only paints the menu bar black), don't count.
    public static func conflicting(in running: [(bundleID: String?, name: String?)]) -> [String] {
        var found: [String] = []
        for app in running {
            let id = app.bundleID?.lowercased() ?? ""
            let name = app.name ?? ""
            if id.hasPrefix("com.pixsnap") { continue }
            let known = knownApps.first { candidate in
                candidate.bundleIDs.contains { $0.lowercased() == id } || candidate.name.caseInsensitiveCompare(name) == .orderedSame
            }
            let title = known?.name ?? (name.range(of: "notch", options: .caseInsensitive) != nil ? name : nil)
            if let title, title != "TopNotch", !found.contains(title) { found.append(title) }
        }
        return found
    }
}
