import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CodexForkMenuTests {
    @Test
    func `purchased balance dedup keeps distinct monthly and purchased pools`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let purchased = CreditsSnapshot(remaining: 50, events: [], updatedAt: now)
        let cost = CodexExtraUsageCost.providerCost(from: purchased)
        #expect(UsageMenuCardView.Model.creditsRepeatExtraUsageBalance(credits: purchased, cost: cost))
        #expect(!UsageMenuCardView.Model.creditsRepeatExtraUsageBalance(credits: nil, cost: cost))
        let capped = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: .init(
                title: "Monthly credit limit",
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))
        #expect(!UsageMenuCardView.Model.creditsRepeatExtraUsageBalance(
            credits: capped, cost: CodexExtraUsageCost.providerCost(from: capped)))
    }

    @Test
    func `render synthetic fork menu when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_FORK_PROOF_DIR"] else { return }
        let dashboard = InlineUsageDashboardModel(
            accessibilityLabel: "Synthetic spend history",
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: "Today", value: "$563.21", emphasis: true),
                .init(title: "Current window", value: "$761.00", emphasis: false),
                .init(title: "30d", value: "$6,587.56", emphasis: false),
                .init(title: "30d tokens", value: "13B", emphasis: false),
            ],
            points: (0..<30).map { index in
                .init(
                    id: "\(index)",
                    label: "Day \(index + 1)",
                    value: Double((index * 37) % 100),
                    accessibilityValue: "Synthetic day")
            },
            detailLines: ["Estimated from token usage, not a subscription bill"],
            quotaWindows: [.init(id: "current", title: "Current window", range: "Synthetic dates", value: "$761")],
            barColor: .cyan,
            currencyCode: "USD")
        var model = Self.model(dashboard: dashboard)
        model.creditsText = "62500 left"
        model.creditsProgressPercent = 100
        model.creditsScaleText = "1K tokens"
        model.limitResetCredits = .init(text: "2 available", items: [
            .init(expiryText: "Expires in 17d 15h", compactExpiryText: "17d 15h"),
            .init(expiryText: "Expires in 24d 13h", compactExpiryText: "24d 13h"),
        ])
        let content = UsageMenuCardView(model: model, width: 320)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("codex-menu.png"))
    }

    private static func model(dashboard: InlineUsageDashboardModel? = nil) -> UsageMenuCardView.Model {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "preview@example.com",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: "Pro 20x",
            metrics: [
                .init(
                    id: "secondary",
                    title: "Weekly",
                    percent: 87,
                    percentStyle: .left,
                    resetText: "Resets in 6d 23h",
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true),
                .init(
                    id: "code-review",
                    title: "Code review",
                    percent: 73,
                    percentStyle: .left,
                    resetText: nil,
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true),
            ],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: dashboard,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .cyan)
    }
}
