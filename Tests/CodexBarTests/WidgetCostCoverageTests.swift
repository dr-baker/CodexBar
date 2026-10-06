import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

struct WidgetCostCoverageTests {
    @Test(arguments: [nil, 100.0] as [Double?])
    func `partial native and Pi costs cannot become exact widget amounts`(nativeCost: Double?) throws {
        let native = CostUsageDailyReport(data: [Self.dayEntry(
            cost: nativeCost, tokens: 399_000_000, unpriced: 1)], summary: nil)
        let pi = CostUsageDailyReport(data: [Self.dayEntry(cost: 2.39, tokens: 1000)], summary: nil)
        let daily = native.merged(with: pi).data
        let snapshot = Self.snapshot(daily: daily)
        let projected = Self.widgetEntry(snapshot)
        let encoded = try JSONEncoder().encode(projected)
        let entry = try JSONDecoder().decode(WidgetSnapshot.ProviderEntry.self, from: encoded)
        let summary = try #require(entry.tokenUsage)

        #expect(snapshot.daily.first?.costUSD == (nativeCost ?? 0) + 2.39)
        #expect(entry.dailyUsage.first?.costUSD == nil)
        #expect(entry.dailyUsage.first?.totalTokens == 399_001_000)
        #expect(!UsageHistoryChartMode.isCostMode(entry.dailyUsage))
        #expect(summary.sessionCostUSD == nil)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == 399_001_000)
        #expect(summary.last30DaysTokens == 399_001_000)
        #expect(CompactMetricFormatter.display(for: entry, metric: .todayCost).value == "—")
        #expect(CompactMetricFormatter.display(for: entry, metric: .last30DaysCost).value == "—")
        #expect(WidgetMetricRows.rows(for: entry, size: .small).map(\.value) == ["399M tokens"])
        #expect(WidgetMetricRows.rows(for: entry, size: .large).map(\.value) == [
            "— · 399M tokens", "— · 399M tokens",
        ])
        #expect(WidgetFallbackHero.make(for: entry)?.value == "399M")
        #expect(WidgetFormat.costAndTokens(
            cost: summary.sessionCostUSD, tokens: summary.sessionTokens) == "— · 399M tokens")
    }

    @Test(arguments: [0.0, 4.0])
    func `fully scanned priced history keeps exact widget money including zero`(cost: Double) throws {
        let entry = Self.widgetEntry(Self.snapshot(daily: [Self.dayEntry(cost: cost, tokens: 600)]))
        let summary = try #require(entry.tokenUsage)

        #expect(entry.dailyUsage.first?.costUSD == cost)
        #expect(UsageHistoryChartMode.isCostMode(entry.dailyUsage))
        #expect(summary.sessionCostUSD == cost)
        #expect(summary.last30DaysCostUSD == cost)
        #expect(summary.sessionTokens == 600)
        #expect(CompactMetricFormatter.display(for: entry, metric: .todayCost).value
            == WidgetFormat.currency(cost, code: "USD"))
    }

    @Test(arguments: ["unpriced", "unmetered", "incomplete", "model-price-gap"])
    func `cost gaps suppress daily and summary money while preserving measured tokens`(gap: String) throws {
        let daily = Self.dayEntry(
            cost: 4,
            tokens: 600,
            unpriced: gap == "unpriced" ? 1 : nil,
            unmetered: gap == "unmetered" ? 1 : nil,
            incomplete: gap == "incomplete" ? 1 : nil,
            modelPriceGap: gap == "model-price-gap")
        let entry = Self.widgetEntry(Self.snapshot(daily: [daily]))
        let summary = try #require(entry.tokenUsage)

        #expect(entry.dailyUsage.first?.costUSD == nil)
        #expect(entry.dailyUsage.first?.totalTokens == 600)
        #expect(!UsageHistoryChartMode.isCostMode(entry.dailyUsage))
        #expect(summary.sessionCostUSD == nil)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == 600)
        #expect(summary.last30DaysTokens == 600)
    }

    @Test(arguments: ["unestablished", "truncated"])
    func `incomplete scan coverage cannot publish exact widget cost totals`(scan: String) throws {
        let snapshot = Self.snapshot(
            daily: [Self.dayEntry(cost: 4, tokens: 600)],
            established: scan != "unestablished",
            partial: scan == "truncated")
        let entry = Self.widgetEntry(snapshot)
        let summary = try #require(entry.tokenUsage)

        #expect(!snapshot.historyIsFullyScanned)
        #expect(entry.dailyUsage.first?.costUSD == nil)
        #expect(!UsageHistoryChartMode.isCostMode(entry.dailyUsage))
        #expect(summary.sessionCostUSD == nil)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == 600)
        #expect(summary.last30DaysTokens == 600)
    }

    @Test
    func `a previous pricing gap suppresses history money but preserves a complete Today amount`() throws {
        let snapshot = Self.snapshot(daily: [
            Self.dayEntry(day: "2023-11-13", cost: 1, tokens: 200, unpriced: 1),
            Self.dayEntry(cost: 4, tokens: 400),
        ])
        let entry = Self.widgetEntry(snapshot)
        let summary = try #require(entry.tokenUsage)

        #expect(entry.dailyUsage.map(\.costUSD) == [nil, 4])
        #expect(entry.dailyUsage.map(\.totalTokens) == [200, 400])
        #expect(!UsageHistoryChartMode.isCostMode(entry.dailyUsage))
        #expect(summary.sessionCostUSD == 4)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == 400)
        #expect(summary.last30DaysTokens == 600)
    }

    @Test(arguments: [UsageProvider.bedrock, .mistral])
    func `latest billing day coverage is checked even when that day precedes Today`(provider: UsageProvider) throws {
        let daily = Self.dayEntry(day: "2023-11-13", cost: 4, tokens: 600, unpriced: 1)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 600,
            sessionCostUSD: 4,
            last30DaysTokens: 600,
            last30DaysCostUSD: 4,
            costProvenance: .vendorMetered,
            daily: [daily],
            updatedAt: Self.now)
        let summary = try #require(UsageStore.widgetTokenUsageSummary(
            from: snapshot, provider: provider, calendar: Self.calendar))

        #expect(summary.sessionCostUSD == nil)
        #expect(summary.last30DaysCostUSD == nil)
        #expect(summary.sessionTokens == 600)
        #expect(summary.sessionLabel == "Latest billing day")
    }

    @Test
    func `widget session completeness follows the configured cost bucket calendar`() throws {
        var calendar = Self.calendar
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 600,
            sessionCostUSD: 4,
            last30DaysTokens: 600,
            last30DaysCostUSD: 4,
            daily: [Self.dayEntry(day: "2023-11-15", cost: 4, tokens: 600, unpriced: 1)],
            updatedAt: Self.now)
        let summary = try #require(UsageStore.widgetTokenUsageSummary(
            from: snapshot, provider: .codex, calendar: calendar))

        #expect(summary.sessionCostUSD == nil)
        #expect(summary.sessionTokens == 600)
    }

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day = "2023-11-14"
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dayEntry(
        day: String = Self.day,
        cost: Double?,
        tokens: Int,
        unpriced: Int? = nil,
        unmetered: Int? = nil,
        incomplete: Int? = nil,
        modelPriceGap: Bool = false) -> CostUsageDailyReport.Entry
    {
        .init(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: 1,
            costUSD: cost,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: [.init(
                modelName: "fixture-model",
                costUSD: modelPriceGap ? nil : cost,
                totalTokens: tokens,
                incompleteRequestCount: incomplete)],
            unpricedRequestCount: unpriced,
            unmeteredRequestCount: unmetered)
    }

    private static func snapshot(
        daily: [CostUsageDailyReport.Entry],
        established: Bool = true,
        partial: Bool = false) -> CostUsageTokenSnapshot
    {
        let today = daily.first { $0.date == Self.day }
        let costs = daily.compactMap(\.costUSD)
        let tokens = daily.compactMap(\.totalTokens)
        return .init(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            historyCoverageIsEstablished: established,
            historyScanIsPartial: partial,
            costProvenance: .listPriceEstimate,
            daily: daily,
            updatedAt: Self.now)
    }

    private static func widgetEntry(_ snapshot: CostUsageTokenSnapshot) -> WidgetSnapshot.ProviderEntry {
        .init(
            provider: .codex,
            updatedAt: snapshot.updatedAt,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: UsageStore.widgetTokenUsageSummary(
                from: snapshot, provider: .codex, calendar: self.calendar),
            dailyUsage: UsageStore.widgetDailyUsagePoints(from: snapshot))
    }
}
