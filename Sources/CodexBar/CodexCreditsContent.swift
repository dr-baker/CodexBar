import CodexBarCore
import SwiftUI

/// Keeps Codex balances and reset inventory together in every menu presentation.
struct CodexCreditsContent: View {
    let model: UsageMenuCardView.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Credits"))
                .font(.body)
                .fontWeight(.medium)
            if let credits = self.model.creditsText {
                CreditsBarContent(
                    creditsText: credits,
                    showsProgress: self.model.creditsShowProgress,
                    progressPercent: self.model.creditsProgressPercent,
                    scaleText: self.model.creditsScaleText,
                    hintText: self.model.creditsHintText,
                    hintCopyText: self.model.creditsHintCopyText,
                    progressColor: self.model.progressColor,
                    showsTitle: false)
            }
            if let resetCredits = self.model.limitResetCredits {
                LimitResetCreditsContent(presentation: resetCredits)
            }
            if let cost = self.model.groupedCodexProviderCost {
                ProviderCostContent(section: cost, progressColor: self.model.progressColor)
            }
        }
    }
}

extension UsageMenuCardView.Model {
    /// Provider-specific by design: Codex groups reset inventory and extra usage with purchased credits.
    var groupsCodexCredits: Bool {
        self.provider == .codex
    }

    var inlineUsageDashboardShowsDetails: Bool {
        !self.groupsCodexCredits
    }

    var hasCreditsSection: Bool {
        self.creditsText != nil ||
            (self.groupsCodexCredits && (self.limitResetCredits != nil || self.providerCost != nil))
    }

    static func creditsRepeatExtraUsageBalance(credits: CreditsSnapshot?, cost: ProviderCostSnapshot?) -> Bool {
        guard let credits, credits.balanceReadSucceeded,
              credits.hasWorkspaceBalance || credits.codexCreditLimit == nil,
              let displayed = credits.displayRemaining,
              let cost, cost.currencyCode == CodexExtraUsageCost.currencyCode,
              let purchased = cost.balance
        else { return false }
        return abs(displayed - purchased) < 0.0001
    }

    var groupedCodexProviderCost: ProviderCostSection? {
        guard self.groupsCodexCredits, var cost = self.providerCost else { return nil }
        // A balance-only Extra usage row repeats the purchased-credit balance already drawn above.
        if self.creditsRepeatExtraUsageBalance, cost.percentUsed == nil { return nil }
        if self.creditsRepeatExtraUsageBalance { cost.balanceLine = nil }
        return cost
    }
}
