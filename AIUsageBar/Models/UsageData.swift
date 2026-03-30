import Foundation

// MARK: - Usage Window
struct UsageWindow: Codable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// 轉換 ISO8601 字串為 Date
    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: resetsAt) { return d }
        return ISO8601DateFormatter().date(from: resetsAt)
    }

    /// 距離重置的人類可讀時間（e.g. "4h 38m"、"2d"、"soon"）
    var timeUntilResetText: String {
        guard let date = resetDate else { return "--" }
        let interval = date.timeIntervalSinceNow
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

    /// 重置日期的短格式（e.g. "4/4"）
    var resetDateText: String {
        guard let date = resetDate else { return "--" }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: date)
    }
}

// MARK: - Extra Usage
struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled    = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits  = "used_credits"
        case utilization
    }
}

// MARK: - Top-level Usage Response
struct UsageData: Codable {
    let fiveHour:        UsageWindow?
    let sevenDay:        UsageWindow?
    let sevenDaySonnet:  UsageWindow?
    let sevenDayOpus:    UsageWindow?
    let extraUsage:      ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour       = "five_hour"
        case sevenDay       = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus   = "seven_day_opus"
        case extraUsage     = "extra_usage"
    }
}
