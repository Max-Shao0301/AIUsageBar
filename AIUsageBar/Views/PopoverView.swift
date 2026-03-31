import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().padding(.horizontal, 16)
            contentView
            Divider().padding(.horizontal, 16)
            footerView
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 8) {
            // Claude icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.95, green: 0.55, blue: 0.2),
                                     Color(red: 0.88, green: 0.25, blue: 0.48)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }

            Text("AI Usage")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            // Refresh Button
            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .rotationEffect(viewModel.isLoading ? .degrees(360) : .degrees(0))
                    .animation(
                        viewModel.isLoading
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.3),
                        value: viewModel.isLoading
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Main Content
    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoading && !viewModel.hasAnyUsageData {
            loadingView
        } else if let error = viewModel.errorMessage, !viewModel.hasAnyUsageData {
            errorView(message: error)
        } else {
            usageView
        }
    }

    // MARK: - Loading
    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.85)
            Text("正在載入用量資料⋯")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Error
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("重試") { viewModel.refresh() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Usage Rows
    private var usageView: some View {
        VStack(spacing: 16) {
            if viewModel.usageData != nil {
                sectionHeader("Claude")

                UsageProgressRow(
                    title:       "Current Session",
                    subtitle:    "5 小時用量",
                    utilization: viewModel.sessionUtilization,
                    resetInfo:   viewModel.sessionResetText
                )

                Divider()

                UsageProgressRow(
                    title:       "Weekly",
                    subtitle:    "7 天用量",
                    utilization: viewModel.weeklyUtilization,
                    resetInfo:   viewModel.weeklyResetText
                )

                // Sonnet (only shown when data is available)
                if viewModel.shouldShowSonnet {
                    Divider()
                    UsageProgressRow(
                        title:       "Weekly · Sonnet",
                        subtitle:    "7 天用量",
                        utilization: viewModel.sonnetUtilization,
                        resetInfo:   viewModel.sonnetResetText
                    )
                }
            }

            if viewModel.shouldShowCodex {
                if viewModel.usageData != nil {
                    Divider()
                }

                sectionHeader("Codex")

                UsageProgressRow(
                    title:       "Current Session",
                    subtitle:    "5 小時用量",
                    utilization: viewModel.codexSessionUtilization,
                    resetInfo:   viewModel.codexSessionResetText
                )

                Divider()

                UsageProgressRow(
                    title:       "Weekly",
                    subtitle:    "7 天用量",
                    utilization: viewModel.codexWeeklyUtilization,
                    resetInfo:   viewModel.codexWeeklyResetText
                )
            }

        }
        .padding(16)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            if title == "Claude" {
                Image("ClaudeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else if title == "Codex" {
                Image("CodexIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    // MARK: - Footer
    private var footerView: some View {
        HStack {
            // Last updated
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("更新：\(viewModel.lastUpdatedText)")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)

            Spacer()

            // Quit
            Button("結束") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Preview
#Preview {
    PopoverView(viewModel: UsageViewModel())
        .frame(width: 320)
}
