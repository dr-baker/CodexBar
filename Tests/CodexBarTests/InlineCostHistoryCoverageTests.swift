import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct InlineCostHistoryCoverageTests {
    @Test(arguments: [nil, 100.0] as [Double?])
    func `native and Pi merge keeps priced subtotals and complete known tokens`(nativeCost: Double?) throws {
        let native = CostUsageDailyReport(data: [Self.entry(
            cost: nativeCost,
            tokens: 399_000_000,
            model: "fixture-native",
            unpriced: 1)], summary: nil)
        let pi = CostUsageDailyReport(data: [Self.entry(
            cost: 2.39, tokens: 1000, model: "fixture-pi")], summary: nil)
        let merged = native.merged(with: pi)
        let snapshot = Self.snapshot(entries: merged.data)
        let menu = try Self.menu(snapshot)
        let dashboard = try #require(menu.inlineUsageDashboard)
        let expectedCost = nativeCost == nil ? "≥ $2.39" : "≥ $102.39"

        #expect(dashboard.kpis.map(\.value) == [expectedCost, expectedCost, "399M", "399M"])
        let point = try #require(dashboard.points.first { $0.id == Self.day })
        #expect(point.value == (nativeCost ?? 0) + 2.39)
        #expect(!point.valueIsComplete)
        #expect(point.hoverDetail?.costIsComplete == false)
        #expect(point.hoverDetail?.tokensAreComplete == true)
        #expect(point.accessibilityValue.contains("\(expectedCost) · 399M tokens"))
        #expect(dashboard.costScaleLabel(maximum: point.value ?? 0).hasPrefix("≥ "))
        #expect(dashboard.summaryNote == "Local API-rate estimate · Partial coverage")
        #expect(!menu.inlineUsageDashboardShowsDetails)
    }

    @Test(arguments: [UsageProvider.codex, .claude, .antigravity])
    func `partial scans qualify money and tokens independently of missing prices`(provider: UsageProvider) throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: 4, tokens: 600)], partialScan: true)
        let dashboard = try #require(Self.menu(snapshot, provider: provider).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["≥ $4.00", "≥ $4.00", "≥ 600", "≥ 600"])
        let point = try #require(dashboard.points.first { $0.id == Self.day })
        #expect(point.value == 4)
        #expect(point.accessibilityValue.contains("≥ $4.00 · ≥ 600 tokens"))
        #expect(dashboard.costScaleLabel(maximum: 4).hasPrefix("≥ "))
        #expect(dashboard.summaryNote == "Local API-rate estimate · Partial coverage")
    }

    @Test
    func `unestablished scan coverage qualifies every recorded total`() throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: 4, tokens: 600)], established: false)
        let dashboard = try #require(Self.menu(snapshot).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["≥ $4.00", "≥ $4.00", "≥ 600", "≥ 600"])
        #expect(dashboard.points.first { $0.id == Self.day }?.hoverDetail?.tokensAreComplete == false)
    }

    @Test
    func `unmetered requests qualify both known subtotals`() throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: 4, tokens: 600, unmetered: 1)])
        let dashboard = try #require(Self.menu(snapshot).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["≥ $4.00", "≥ $4.00", "≥ 600", "≥ 600"])
        #expect(dashboard.points.first { $0.id == Self.day }?.accessibilityValue
            .contains("≥ $4.00 · ≥ 600 tokens") == true)
    }

    @Test
    func `missing final usage qualifies subtotals while retaining the exclusion marker`() throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: 4, tokens: 600, incomplete: 1)])
        let dashboard = try #require(Self.menu(snapshot).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == [
            "≥ $4.00 · Incomplete", "≥ $4.00 · Incomplete", "≥ 600 · Incomplete", "≥ 600 · Incomplete",
        ])
        #expect(dashboard.points.first { $0.id == Self.day }?.accessibilityValue
            .contains("≥ $4.00 · ≥ 600 tokens · Incomplete") == true)
    }

    @Test
    func `unknown prices retain known tokens without inventing money`() throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: nil, tokens: 600, unpriced: 1)])
        let dashboard = try #require(Self.menu(snapshot).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["—", "—", "600", "600"])
        let point = try #require(dashboard.points.first { $0.id == Self.day })
        #expect(point.value == nil)
        #expect(point.accessibilityValue.hasSuffix(": — · 600 tokens"))
        #expect(point.hoverDetail?.tokensAreComplete == true)
        #expect(dashboard.costScaleLabel(maximum: 0) == " ")
    }

    @Test
    func `legacy model price gaps qualify money without qualifying known token totals`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: Self.day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 600,
            costUSD: 4,
            modelsUsed: ["fixture-priced", "fixture-unpriced"],
            modelBreakdowns: [
                .init(modelName: "fixture-priced", costUSD: 4, totalTokens: 400),
                .init(modelName: "fixture-unpriced", costUSD: nil, totalTokens: 200),
            ])
        let dashboard = try #require(Self.menu(Self.snapshot(entries: [entry])).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["≥ $4.00", "≥ $4.00", "600", "600"])
        #expect(dashboard.points.first { $0.id == Self.day }?.accessibilityValue
            .contains("≥ $4.00 · 600 tokens") == true)
    }

    @Test
    func `a price gap on a previous day does not qualify Today's complete amount`() throws {
        let snapshot = Self.snapshot(entries: [
            Self.entry(day: "2023-11-13", cost: nil, tokens: 200, unpriced: 1),
            Self.entry(cost: 4, tokens: 400),
        ])
        let dashboard = try #require(Self.menu(snapshot).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["$4.00", "≥ $4.00", "400", "600"])
        #expect(dashboard.points.first { $0.id == Self.day }?.valueIsComplete == true)
        #expect(dashboard.costScaleLabel(maximum: 4).hasPrefix("≥ "))
    }

    @Test(arguments: [CostProvenance.vendorMetered, .mixed, .unknown])
    func `compact provenance preserves the source of reported amounts`(provenance: CostProvenance) throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: 4, tokens: 600)], provenance: provenance)
        let dashboard = try #require(Self.menu(snapshot, provider: .claude).inlineUsageDashboard)
        let expected = switch provenance {
        case .vendorMetered: "Reported spend"
        case .mixed: "Mixed cost sources"
        case .unknown: "Recorded cost"
        case .listPriceEstimate: "Local API-rate estimate"
        }

        #expect(dashboard.kpis.map(\.value) == ["$4.00", "$4.00", "600", "600"])
        #expect(dashboard.summaryNote == expected)
        #expect(!dashboard.costScaleLabel(maximum: 4).hasPrefix("≥ "))
    }

    @Test
    func `complete zero usage remains exact`() throws {
        let dashboard = try #require(Self.menu(Self.snapshot(entries: [Self.entry(cost: 0, tokens: 0)]))
            .inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["$0.00", "$0.00", "0", "0"])
        #expect(dashboard.points.first { $0.id == Self.day }?.accessibilityValue
            .hasSuffix(": $0.00 · 0 tokens") == true)
        #expect(dashboard.summaryNote == "Local API-rate estimate")
    }

    @Test
    func `token-only dashboards qualify incomplete scans without pricing token counts`() throws {
        let snapshot = Self.snapshot(entries: [Self.entry(cost: nil, tokens: 600, unpriced: 1)], partialScan: true)
        let dashboard = try #require(Self.menu(snapshot, provider: .muse).inlineUsageDashboard)

        #expect(dashboard.kpis.map(\.value) == ["≥ 600 tokens", "≥ 600 tokens"])
        #expect(dashboard.points.first { $0.id == Self.day }?.accessibilityValue.hasSuffix(": ≥ 600 tokens") == true)
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day = "2023-11-14"
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func entry(
        day: String = Self.day,
        cost: Double?,
        tokens: Int?,
        model: String = "fixture-model",
        unpriced: Int? = nil,
        unmetered: Int? = nil,
        incomplete: Int? = nil) -> CostUsageDailyReport.Entry
    {
        .init(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: [model],
            modelBreakdowns: [.init(
                modelName: model,
                costUSD: cost,
                totalTokens: tokens,
                incompleteRequestCount: incomplete)],
            unpricedRequestCount: unpriced,
            unmeteredRequestCount: unmetered)
    }

    private static func snapshot(
        entries: [CostUsageDailyReport.Entry],
        partialScan: Bool = false,
        established: Bool = true,
        provenance: CostProvenance = .listPriceEstimate) -> CostUsageTokenSnapshot
    {
        let today = entries.first { $0.date == Self.day }
        let costs = entries.compactMap(\.costUSD)
        let tokens = entries.compactMap(\.totalTokens)
        return .init(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            historyCoverageIsEstablished: established,
            historyScanIsPartial: partialScan,
            costProvenance: provenance,
            daily: entries,
            updatedAt: Self.now)
    }

    private static func menu(
        _ snapshot: CostUsageTokenSnapshot,
        provider: UsageProvider = .codex) throws -> UsageMenuCardView.Model
    {
        try UsageMenuCardView.Model.make(.init(
            provider: provider,
            metadata: #require(ProviderDefaults.metadata[provider]),
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot,
            tokenError: nil,
            account: .init(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            tokenCostMenuSectionEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            preferredCurrencyCode: "USD",
            costUsageBucketCalendar: self.calendar,
            now: self.now))
    }
}
