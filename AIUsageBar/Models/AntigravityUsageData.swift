import Foundation

struct AntigravityUsageWindow {
    let usedPercent: Double
    let resetAt: Date?

    var utilization: Double { usedPercent }

    var timeUntilResetText: String {
        guard let resetAt else { return "--" }
        let interval = resetAt.timeIntervalSinceNow
        guard interval > 0 else { return "soon" }

        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours >= 48 {
            return "\(hours / 24)d"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var resetDateText: String {
        guard let resetAt else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: resetAt)
    }
}

struct AntigravityQuotaGroup {
    let displayName: String
    let fiveHour: AntigravityUsageWindow?
    let weekly: AntigravityUsageWindow?
}

struct AntigravityUsageData {
    let gemini: AntigravityQuotaGroup?
    let claudeAndGPT: AntigravityQuotaGroup?
}
