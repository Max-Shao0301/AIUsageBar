import Foundation
import Combine

@MainActor
final class UsageViewModel: ObservableObject {

    // MARK: - Published State
    @Published var usageData: UsageData?
    @Published var codexUsageData: CodexUsageData?
    @Published var antigravityUsageData: AntigravityUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var codexErrorMessage: String?
    @Published var antigravityErrorMessage: String?
    @Published var lastUpdated: Date?

    // MARK: - Auto Refresh
    private var refreshTask: Task<Void, Never>?
    private let autoRefreshInterval: TimeInterval = 300  // 5 minutes

    // MARK: - Init
    init() {
        Task { await fetchUsage() }
        startAutoRefresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Public: Manual Trigger
    func refresh() {
        Task { await fetchUsage() }
    }

    // MARK: - Private: Fetch Data
    private func fetchUsage() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        codexErrorMessage = nil
        antigravityErrorMessage = nil

        async let claudeResult = fetchClaudeResult()
        async let codexResult = fetchCodexResult()
        async let antigravityResult = fetchAntigravityResult()

        let (claude, codex, antigravity) = await (claudeResult, codexResult, antigravityResult)
        var hasFreshSuccess = false

        switch claude {
        case .success(let data):
            usageData = data
            hasFreshSuccess = true
        case .failure(let error):
            if usageData == nil {
                errorMessage = error.localizedDescription
            }
        }

        switch codex {
        case .success(let data):
            codexUsageData = data
            hasFreshSuccess = true
        case .failure(let error):
            if codexUsageData == nil {
                codexErrorMessage = error.localizedDescription
            }
        }

        switch antigravity {
        case .success(let data):
            antigravityUsageData = data
            hasFreshSuccess = true
        case .failure(let error):
            if antigravityUsageData == nil {
                antigravityErrorMessage = error.localizedDescription
            }
        }

        if !hasAnyUsageData {
            let errors = [
                errorMessage.map { "Claude：\($0)" },
                codexErrorMessage.map { "Codex：\($0)" },
                antigravityErrorMessage.map { "Antigravity：\($0)" }
            ].compactMap { $0 }
            errorMessage = errors.joined(separator: "\n")
        }

        if hasFreshSuccess {
            lastUpdated = Date()
        }

        persistWidgetSnapshot()

        isLoading = false
    }

    private func persistWidgetSnapshot() {
        guard hasAnyUsageData else { return }

        let snapshot = WidgetUsageSnapshot(
            updatedAt: Date(),
            claudeSessionUtilization: usageData?.fiveHour?.utilization,
            claudeWeeklyUtilization: usageData?.sevenDay?.utilization,
            claudeSessionResetText: usageData?.fiveHour?.timeUntilResetText,
            claudeWeeklyResetText: usageData?.sevenDay?.resetDateText,
            codexSessionUtilization: codexUsageData?.fiveHour?.utilization,
            codexWeeklyUtilization: codexUsageData?.sevenDay?.utilization,
            codexSessionResetText: codexUsageData?.fiveHour?.timeUntilResetText,
            codexWeeklyResetText: codexUsageData?.sevenDay?.resetDateText,
            antigravityGeminiSessionUtilization: antigravityUsageData?.gemini?.fiveHour?.utilization,
            antigravityGeminiWeeklyUtilization: antigravityUsageData?.gemini?.weekly?.utilization,
            antigravityGeminiSessionResetText: antigravityUsageData?.gemini?.fiveHour?.timeUntilResetText,
            antigravityGeminiWeeklyResetText: antigravityUsageData?.gemini?.weekly?.resetDateText,
            antigravityClaudeGPTSessionUtilization: antigravityUsageData?.claudeAndGPT?.fiveHour?.utilization,
            antigravityClaudeGPTWeeklyUtilization: antigravityUsageData?.claudeAndGPT?.weekly?.utilization,
            antigravityClaudeGPTSessionResetText: antigravityUsageData?.claudeAndGPT?.fiveHour?.timeUntilResetText,
            antigravityClaudeGPTWeeklyResetText: antigravityUsageData?.claudeAndGPT?.weekly?.resetDateText
        )

        WidgetSnapshotStore.save(snapshot)
    }

    private func fetchClaudeResult() async -> Result<UsageData, Error> {
        do {
            return .success(try await ClaudeService.shared.fetchUsage())
        } catch {
            print("❌ [ClaudeService] 錯誤：\(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func fetchCodexResult() async -> Result<CodexUsageData, Error> {
        do {
            return .success(try await CodexUsageService.shared.fetchUsage())
        } catch {
            return .failure(error)
        }
    }

    private func fetchAntigravityResult() async -> Result<AntigravityUsageData, Error> {
        do {
            return .success(try await AntigravityUsageService.shared.fetchUsage())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Private: Background Auto-Refresh
    private func startAutoRefresh() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.autoRefreshInterval ?? 300) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.fetchUsage()
            }
        }
    }

    // MARK: - Computed: Convenience properties for UI

    var hasAnyUsageData: Bool {
        usageData != nil || codexUsageData != nil || antigravityUsageData != nil
    }

    // Claude
    var sessionUtilization: Double  { usageData?.fiveHour?.utilization ?? 0 }
    var weeklyUtilization: Double   { usageData?.sevenDay?.utilization ?? 0 }
    var sonnetUtilization: Double   { usageData?.sevenDaySonnet?.utilization ?? 0 }

    var sessionResetText: String    { usageData?.fiveHour?.timeUntilResetText ?? "--" }
    var weeklyResetText: String     { usageData?.sevenDay?.resetDateText ?? "--" }
    var sonnetResetText: String     { usageData?.sevenDaySonnet?.resetDateText ?? "--" }

    // Codex
    var codexSessionUtilization: Double { codexUsageData?.fiveHour?.utilization ?? 0 }
    var codexWeeklyUtilization: Double  { codexUsageData?.sevenDay?.utilization ?? 0 }

    var codexSessionResetText: String { codexUsageData?.fiveHour?.timeUntilResetText ?? "--" }
    var codexWeeklyResetText: String  { codexUsageData?.sevenDay?.resetDateText ?? "--" }

    // Antigravity
    var antigravityGeminiSessionUtilization: Double { antigravityUsageData?.gemini?.fiveHour?.utilization ?? 0 }
    var antigravityGeminiWeeklyUtilization: Double  { antigravityUsageData?.gemini?.weekly?.utilization ?? 0 }
    var antigravityGeminiSessionResetText: String   { antigravityUsageData?.gemini?.fiveHour?.timeUntilResetText ?? "--" }
    var antigravityGeminiWeeklyResetText: String    { antigravityUsageData?.gemini?.weekly?.resetDateText ?? "--" }

    var antigravityClaudeGPTSessionUtilization: Double { antigravityUsageData?.claudeAndGPT?.fiveHour?.utilization ?? 0 }
    var antigravityClaudeGPTWeeklyUtilization: Double  { antigravityUsageData?.claudeAndGPT?.weekly?.utilization ?? 0 }
    var antigravityClaudeGPTSessionResetText: String   { antigravityUsageData?.claudeAndGPT?.fiveHour?.timeUntilResetText ?? "--" }
    var antigravityClaudeGPTWeeklyResetText: String    { antigravityUsageData?.claudeAndGPT?.weekly?.resetDateText ?? "--" }

    /// Highest utilization rate (used for Menu Bar icon display)
    var maxUtilization: Double {
        max(sessionUtilization, weeklyUtilization, sonnetUtilization,
            codexSessionUtilization, codexWeeklyUtilization,
            antigravityGeminiSessionUtilization, antigravityGeminiWeeklyUtilization,
            antigravityClaudeGPTSessionUtilization, antigravityClaudeGPTWeeklyUtilization)
    }

    /// Text displayed in the Menu Bar
    var statusBarLabel: String {
        guard hasAnyUsageData else { return "..." }
        return "\(Int(maxUtilization.rounded()))%"
    }

    /// Human-readable time since the last update
    var lastUpdatedText: String {
        guard let date = lastUpdated else { return "從未更新" }
        let secs = Date().timeIntervalSince(date)
        if secs < 10  { return "剛剛" }
        if secs < 60  { return "\(Int(secs)) 秒前" }
        return "\(Int(secs / 60)) 分鐘前"
    }

    /// Whether to show the Sonnet-specific row (data is present and > 0)
    var shouldShowSonnet: Bool {
        (usageData?.sevenDaySonnet?.utilization ?? 0) > 0
    }

    var shouldShowCodex: Bool {
        codexUsageData != nil
    }

    var shouldShowAntigravity: Bool {
        antigravityUsageData != nil
    }
}
