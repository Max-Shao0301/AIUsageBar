import Foundation

// MARK: - Codex Usage Window
struct CodexUsageWindow: Codable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var utilization: Double {
        usedPercent ?? 0
    }

    var resetDate: Date? {
        guard let resetAt else { return nil }
        return Date(timeIntervalSince1970: resetAt)
    }

    var timeUntilResetText: String {
        let interval: TimeInterval
        if let resetAfterSeconds {
            interval = resetAfterSeconds
        } else if let resetDate {
            interval = resetDate.timeIntervalSinceNow
        } else {
            return "--"
        }

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
        guard let date = resetDate else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}

// MARK: - Codex Rate Limit
struct CodexRateLimit: Codable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

// MARK: - Codex Usage Response
struct CodexUsageData: Codable {
    let userId: String?
    let accountId: String?
    let email: String?
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accountId = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    var fiveHour: CodexUsageWindow? {
        rateLimit?.primaryWindow
    }

    var sevenDay: CodexUsageWindow? {
        rateLimit?.secondaryWindow
    }
}
