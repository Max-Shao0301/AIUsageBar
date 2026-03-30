import SwiftUI

struct UsageProgressRow: View {

    let title:       String
    let subtitle:    String
    let utilization: Double   // 0 ~ 100
    let resetInfo:   String

    // MARK: - Computed
    private var fraction: Double { min(max(utilization / 100, 0), 1) }

    private var barColor: Color {
        switch utilization {
        case ..<60:  return Color(red: 0.18, green: 0.72, blue: 0.56)   // 綠
        case ..<80:  return .orange
        default:     return .red
        }
    }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // 標題列
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%%", utilization))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(barColor)
                    Text("重置 \(resetInfo)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // 進度條
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 背景軌道
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 8)

                    // 進度填色
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.75), barColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0),
                               height: 8)
                        .animation(.easeOut(duration: 0.6), value: fraction)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        UsageProgressRow(title: "Current Session", subtitle: "5-hour window",
                         utilization: 6,   resetInfo: "4h 38m")
        UsageProgressRow(title: "Weekly (All Models)", subtitle: "7-day rolling",
                         utilization: 13,  resetInfo: "4/4")
        UsageProgressRow(title: "Weekly (Sonnet)", subtitle: "7-day rolling",
                         utilization: 75,  resetInfo: "4/4")
        UsageProgressRow(title: "Danger Zone", subtitle: "test",
                         utilization: 92,  resetInfo: "soon")
    }
    .padding(20)
    .frame(width: 320)
}
