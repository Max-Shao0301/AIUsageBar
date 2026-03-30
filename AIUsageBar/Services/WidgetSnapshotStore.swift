import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct WidgetUsageSnapshot: Codable {
    let updatedAt: Date

    let claudeSessionUtilization: Double?
    let claudeWeeklyUtilization: Double?
    let claudeSessionResetText: String?
    let claudeWeeklyResetText: String?

    let codexSessionUtilization: Double?
    let codexWeeklyUtilization: Double?
    let codexSessionResetText: String?
    let codexWeeklyResetText: String?
}

enum WidgetSnapshotStore {
    static let appGroupID = "group.max.shao.AIUsageBar"
    private static let fileName = "usage_snapshot.json"

    /// Returns the shared App Group container URL.
    /// Sandboxed processes get it from the system; non-sandboxed apps
    /// construct the well-known path directly so they can still write data.
    static func containerURL() -> URL? {
        // Try the official API first (works for sandboxed processes, e.g. the widget).
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return url
        }

        // Non-sandboxed fallback: macOS stores App Group containers at
        // ~/Library/Group Containers/<group-id>/
        let groupContainersURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(appGroupID)

        // Create the directory if it doesn't exist yet.
        try? FileManager.default.createDirectory(at: groupContainersURL,
                                                  withIntermediateDirectories: true)
        return groupContainersURL
    }

    static func save(_ snapshot: WidgetUsageSnapshot) {
        guard let containerURL = containerURL() else {
            #if DEBUG
            print("⚠️ [WidgetSnapshotStore] App Group container not found: \(appGroupID)")
            print("⚠️ 請確認 Signing & Capabilities 已為兩個 Target 加入 App Groups")
            #endif
            return
        }
        #if DEBUG
        print("✅ [WidgetSnapshotStore] Saving to: \(containerURL.path)")
        #endif

        let fileURL = containerURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])

            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget")
            #endif
        } catch {
            #if DEBUG
            print("[WidgetSnapshotStore] save failed: \(error.localizedDescription)")
            #endif
        }
    }
}
