import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// AI tab card exposing the three Number Formatting modes
/// (Off / Deterministic / Smart). Visual layout mirrors the Raw/Clean
/// mode cards at the top of the Vocabulary tab — three mini-cards in
/// a horizontal grid, accent checkmark on the selected card.
///
/// Lives in `SettingsView.aiTabContent` between the AI Provider card
/// (which embeds AI Formatter) and the AI Subtitle Refinement card —
/// the cluster of LLM-driven transcript polish steps.
struct NumberFormattingCard: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var llmSettingsViewModel: LLMSettingsViewModel
    let onRequestProviderScroll: () -> Void

    @State private var hoveredModeRaw: String?
    @State private var isCardHovered = false

    private var selectedMode: NumberRefinementMode {
        NumberRefinementMode(rawValue: settingsViewModel.numberRefinementMode) ?? .off
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            modeGrid
            examplesPanel
            if selectedMode == .smart && !llmSettingsViewModel.isConfigured {
                providerHint
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isCardHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isCardHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isCardHovered = hovering
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "number")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Number Formatting")
                    .font(DesignSystem.Typography.sectionTitle)
                Text("How spelled-out numbers get converted to digits.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 200), spacing: DesignSystem.Spacing.md)],
            spacing: DesignSystem.Spacing.md
        ) {
            ForEach(NumberRefinementMode.allCases, id: \.self) { mode in
                modeCard(mode)
            }
        }
    }

    private func modeCard(_ mode: NumberRefinementMode) -> some View {
        let isSelected = selectedMode == mode
        let isHovered = hoveredModeRaw == mode.rawValue
        return Button {
            settingsViewModel.numberRefinementMode = mode.rawValue
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: icon(for: mode))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.accent)
                    }
                }
                Text(mode.displayTitle)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(.primary)
                Text(subtitle(for: mode))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(mode.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredModeRaw = hovering ? mode.rawValue : nil
            }
        }
    }

    private func icon(for mode: NumberRefinementMode) -> String {
        switch mode {
        case .off: return "circle.slash"
        case .deterministic: return "number"
        case .smart: return "sparkles"
        }
    }

    private func subtitle(for mode: NumberRefinementMode) -> String {
        switch mode {
        case .off: return "No changes"
        case .deterministic: return "Rule-based"
        case .smart: return "Rules + AI"
        }
    }

    private var examplesPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Examples")
                .font(DesignSystem.Typography.micro.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(examples(for: selectedMode), id: \.0) { item in
                exampleRow(input: item.0, output: item.1, fires: item.2)
            }
        }
        .padding(.leading, DesignSystem.Spacing.sm)
    }

    private func examples(for mode: NumberRefinementMode) -> [(String, String, Bool)] {
        switch mode {
        case .off:
            return [
                ("twenty-five reps", "twenty-five reps", false),
                ("next thirty seconds", "next thirty seconds", false),
            ]
        case .deterministic:
            return [
                ("next thirty seconds", "next 30 seconds", true),
                ("forty-five reps", "45 reps", true),
                ("one of them", "one of them — single-digit words skipped", false),
            ]
        case .smart:
            return [
                ("next thirty seconds", "next 30 seconds", true),
                ("nineteen ninety-five", "1995", true),
                ("ten thirty AM", "10:30 AM", true),
                ("two point five seconds", "2.5 seconds", true),
            ]
        }
    }

    private func exampleRow(input: String, output: String, fires: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: fires ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(fires ? DesignSystem.Colors.successGreen : .secondary)
            Text("\"\(input)\"")
                .font(DesignSystem.Typography.caption.monospaced())
                .foregroundStyle(.primary)
            Text("→")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
            Text(output)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var providerHint: some View {
        Button(action: onRequestProviderScroll) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Smart needs an AI provider. Without one, Smart behaves like Deterministic.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Set up →")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.warningAmber.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
