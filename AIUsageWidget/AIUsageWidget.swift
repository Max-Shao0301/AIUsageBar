import WidgetKit
import SwiftUI
import Foundation

private struct WidgetUsageSnapshot: Codable {
    let updatedAt: Date

    let claudeSessionUtilization: Double?
    let claudeWeeklyUtilization: Double?
    let claudeSessionResetText: String?
    let claudeWeeklyResetText: String?

    let codexSessionUtilization: Double?
    let codexWeeklyUtilization: Double?
    let codexSessionResetText: String?
    let codexWeeklyResetText: String?

    let antigravityGeminiSessionUtilization: Double?
    let antigravityGeminiWeeklyUtilization: Double?
    let antigravityGeminiSessionResetText: String?
    let antigravityGeminiWeeklyResetText: String?

    let antigravityClaudeGPTSessionUtilization: Double?
    let antigravityClaudeGPTWeeklyUtilization: Double?
    let antigravityClaudeGPTSessionResetText: String?
    let antigravityClaudeGPTWeeklyResetText: String?
}

private enum UsageSnapshotLoader {
    static let appGroupID = "group.max.shao.AIUsageBar"
    static let fileName = "usage_snapshot.json"

    static func load() -> WidgetUsageSnapshot? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }

        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetUsageSnapshot.self, from: data)
    }
}

private struct AIUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetUsageSnapshot?
}

private struct AIUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> AIUsageEntry {
        AIUsageEntry(
            date: Date(),
            snapshot: WidgetUsageSnapshot(
                updatedAt: Date(),
                claudeSessionUtilization: 42,
                claudeWeeklyUtilization: 65,
                claudeSessionResetText: "2h 10m",
                claudeWeeklyResetText: "4/4",
                codexSessionUtilization: 18,
                codexWeeklyUtilization: 27,
                codexSessionResetText: "3h 40m",
                codexWeeklyResetText: "4/4",
                antigravityGeminiSessionUtilization: 12,
                antigravityGeminiWeeklyUtilization: 34,
                antigravityGeminiSessionResetText: "4h 20m",
                antigravityGeminiWeeklyResetText: "4/4",
                antigravityClaudeGPTSessionUtilization: 48,
                antigravityClaudeGPTWeeklyUtilization: 56,
                antigravityClaudeGPTSessionResetText: "3h 10m",
                antigravityClaudeGPTWeeklyResetText: "4/4"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AIUsageEntry) -> Void) {
        completion(AIUsageEntry(date: Date(), snapshot: UsageSnapshotLoader.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIUsageEntry>) -> Void) {
        let now = Date()
        let entry = AIUsageEntry(date: now, snapshot: UsageSnapshotLoader.load())
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

private struct AIUsageWidgetView: View {
    let entry: AIUsageEntry

    var body: some View {
        largeView
            .modifier(WidgetContainerBackgroundModifier())
    }
}

private struct WidgetContainerBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.containerBackground(.fill.tertiary, for: .widget)
        } else {
            content.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private extension AIUsageWidgetView {

    var largeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI Usage")
                    .font(.headline)
                Spacer()
                Text(relativeUpdatedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            .padding(.bottom, 10)

            Divider()

            if let snapshot = entry.snapshot {
                usageList(snapshot)
            } else {
                Spacer()
                Text("尚無資料，請先開啟 AIUsageBar。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
    }

    func usageList(_ snapshot: WidgetUsageSnapshot) -> some View {
        VStack(spacing: 0) {
            usageProviderSection(name: "Claude", icon: "ClaudeIcon",
                                 fiveHour: snapshot.claudeSessionUtilization,
                                 fiveHourReset: snapshot.claudeSessionResetText,
                                 weekly: snapshot.claudeWeeklyUtilization,
                                 weeklyReset: snapshot.claudeWeeklyResetText)
            Divider()

            usageProviderSection(name: "Codex", icon: "CodexIcon",
                                 fiveHour: snapshot.codexSessionUtilization,
                                 fiveHourReset: snapshot.codexSessionResetText,
                                 weekly: snapshot.codexWeeklyUtilization,
                                 weeklyReset: snapshot.codexWeeklyResetText)
            Divider()

            usageProviderSection(name: "Antigravity (Gemini model)", icon: "GeminiIcon",
                                 fiveHour: snapshot.antigravityGeminiSessionUtilization,
                                 fiveHourReset: snapshot.antigravityGeminiSessionResetText,
                                 weekly: snapshot.antigravityGeminiWeeklyUtilization,
                                 weeklyReset: snapshot.antigravityGeminiWeeklyResetText)
            Divider()

            usageProviderSection(name: "Antigravity (Other model)", icon: "GeminiIcon",
                                 fiveHour: snapshot.antigravityClaudeGPTSessionUtilization,
                                 fiveHourReset: snapshot.antigravityClaudeGPTSessionResetText,
                                 weekly: snapshot.antigravityClaudeGPTWeeklyUtilization,
                                 weeklyReset: snapshot.antigravityClaudeGPTWeeklyResetText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func usageProviderSection(name: String,
                              icon: String,
                              fiveHour: Double?,
                              fiveHourReset: String?,
                              weekly: Double?,
                              weeklyReset: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            VStack(alignment: .leading, spacing: 6) {
                usageDetailLine(label: "5H", utilization: fiveHour, resetText: fiveHourReset)
                usageDetailLine(label: "Weekly", utilization: weekly, resetText: weeklyReset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .leading)
    }

    func usageDetailLine(label: String,
                         utilization: Double?,
                         resetText: String?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            HStack(spacing: 4) {
                Text("Used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Int((utilization ?? 0).rounded()))%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorForValue(utilization ?? 0))
            }
            .frame(width: 82, alignment: .leading)
            Text("· \(label == "Weekly" ? "Resets on" : "Resets in") \(resetText ?? "--")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    func colorForValue(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 60 { return .orange }
        return .green
    }

    var relativeUpdatedText: String {
        guard let date = entry.snapshot?.updatedAt else { return "--" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 10 { return "剛剛" }
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m"
    }

}

struct AIUsageWidget: Widget {
    private let kind = "AIUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIUsageProvider()) { entry in
            AIUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("顯示 Claude、Codex 與 Antigravity 用量")
        .supportedFamilies([.systemLarge])
    }
}
