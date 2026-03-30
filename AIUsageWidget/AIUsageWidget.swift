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
                codexWeeklyResetText: "4/4"
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

private struct CompactMetricRow: View {
    let label: String
    let utilization: Double?
    let resetText: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(resetText ?? "--")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(Int((utilization ?? 0).rounded()))%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(colorForValue(utilization ?? 0))
        }
    }

    private func colorForValue(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 60 { return .orange }
        return .green
    }
}

private struct MetricRow: View {
    let title: String
    let utilization: Double?
    let resetText: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(resetText ?? "--")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int((utilization ?? 0).rounded()))%")
                .font(.headline)
                .foregroundStyle(colorForValue(utilization ?? 0))
        }
    }

    private func colorForValue(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 60 { return .orange }
        return .green
    }
}

private struct AIUsageWidgetView: View {
    let entry: AIUsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                smallView
            } else {
                mediumView
            }
        }
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

    var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Usage")
                .font(.headline)

            if let s = entry.snapshot {
                MetricRow(title: "Claude 5H", utilization: s.claudeSessionUtilization, resetText: s.claudeSessionResetText)
                MetricRow(title: "Codex 5H", utilization: s.codexSessionUtilization, resetText: s.codexSessionResetText)
            } else {
                Text("尚無資料")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
    }

    var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Spacer()
                Text(relativeUpdatedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let s = entry.snapshot {
                // 兩欄並排：Claude | Codex
                HStack(alignment: .top, spacing: 8) {
                    // Claude 欄
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image("ClaudeIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 13, height: 13)
                            Text("Claude")
                                .font(.caption2).bold()
                                .foregroundStyle(.secondary)
                        }
                        CompactMetricRow(label: "Current Session", utilization: s.claudeSessionUtilization, resetText: s.claudeSessionResetText)
                        CompactMetricRow(label: "Weekly", utilization: s.claudeWeeklyUtilization, resetText: s.claudeWeeklyResetText)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    // Codex 欄
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image("CodexIcon")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 13, height: 13)
                            Text("Codex")
                                .font(.caption2).bold()
                                .foregroundStyle(.secondary)
                        }
                        CompactMetricRow(label: "Current Session", utilization: s.codexSessionUtilization, resetText: s.codexSessionResetText)
                        CompactMetricRow(label: "Weekly", utilization: s.codexWeeklyUtilization, resetText: s.codexWeeklyResetText)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Spacer()
                Text("尚無資料，請先開啟 AIUsageBar。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
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
        .description("顯示 Claude / Codex 用量")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
