import Foundation
import Combine

@MainActor
final class UsageViewModel: ObservableObject {

    // MARK: - Published State
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    // MARK: - Auto Refresh
    private var refreshTask: Task<Void, Never>?
    private let autoRefreshInterval: TimeInterval = 300  // 5 分鐘

    // MARK: - Init
    init() {
        Task { await fetchUsage() }
        startAutoRefresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public: 手動觸發
    func refresh() {
        Task { await fetchUsage() }
    }

    // MARK: - Private: 取得資料
    private func fetchUsage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            usageData    = try await ClaudeService.shared.fetchUsage()
            lastUpdated  = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Private: 背景定時更新
    private func startAutoRefresh() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.autoRefreshInterval ?? 300) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.fetchUsage()
            }
        }
    }

    // MARK: - Computed: UI 用的便利屬性

    var sessionUtilization: Double  { usageData?.fiveHour?.utilization  ?? 0 }
    var weeklyUtilization: Double   { usageData?.sevenDay?.utilization  ?? 0 }
    var sonnetUtilization: Double   { usageData?.sevenDaySonnet?.utilization ?? 0 }

    var sessionResetText: String    { usageData?.fiveHour?.timeUntilResetText ?? "--" }
    var weeklyResetText: String     { usageData?.sevenDay?.resetDateText       ?? "--" }
    var sonnetResetText: String     { usageData?.sevenDaySonnet?.resetDateText ?? "--" }

    /// 最高使用率（用於 Menu Bar icon 顯示）
    var maxUtilization: Double {
        max(sessionUtilization, weeklyUtilization)
    }

    /// Menu Bar 顯示文字
    var statusBarLabel: String {
        guard usageData != nil else { return "..." }
        return "\(Int(maxUtilization))%"
    }

    /// 上次更新的人類可讀時間
    var lastUpdatedText: String {
        guard let date = lastUpdated else { return "從未更新" }
        let secs = Date().timeIntervalSince(date)
        if secs < 10  { return "剛剛" }
        if secs < 60  { return "\(Int(secs)) 秒前" }
        return "\(Int(secs / 60)) 分鐘前"
    }

    /// 是否顯示 Sonnet 專屬列（有資料且 > 0）
    var shouldShowSonnet: Bool {
        (usageData?.sevenDaySonnet?.utilization ?? 0) > 0
    }
}
