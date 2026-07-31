import SwiftUI

struct AIApprovalStatusView: View {
    let state: AIApprovalPresentationState
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 5 : 8) {
            statusIcon
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.52))
                            .lineLimit(2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: "，"))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.phase {
        case .evaluating:
            ProgressView()
                .controlSize(.mini)
                .tint(color)
        case .recommendation(let decision, _, _):
            Image(systemName: decision == .approve ? "brain.head.profile.fill" : "brain.head.profile")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundColor(color)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundColor(color)
        }
    }

    private var title: String {
        switch state.phase {
        case .evaluating:
            return AppLocalization.string("智能审批判断中，可随时手动处理")
        case .recommendation(let decision, let risk, _):
            let choice = AppLocalization.string(decision == .approve ? "建议允许" : "建议拒绝")
            return "\(choice) · \(AppLocalization.string(risk.title))"
        case .failed:
            return AppLocalization.string("智能审批失败，已转人工")
        }
    }

    private var detail: String? {
        switch state.phase {
        case .evaluating:
            return nil
        case .recommendation(_, _, let reason):
            return reason
        case .failed(let message):
            return AppLocalization.string(message)
        }
    }

    private var color: Color {
        switch state.phase {
        case .evaluating:
            return SettingsCategory.aiApproval.tint
        case .recommendation(let decision, _, _):
            return decision == .approve ? TerminalColors.green : TerminalColors.amber
        case .failed:
            return TerminalColors.amber
        }
    }
}
