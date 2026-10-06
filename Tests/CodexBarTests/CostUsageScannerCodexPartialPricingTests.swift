import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerCodexPartialPricingTests {
    @Test(arguments: [false, true])
    func `canonical mixed pricing retains proven daily and timed dollars`(hasUnpricedTokens: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let priced = fixture.row(index: 0, knownCostNanos: 2_500_000_000)
        let unpriced = fixture.row(
            index: 1,
            unpricedTokens: hasUnpricedTokens ? 150_010 : nil,
            pricingModel: hasUnpricedTokens ? fixture.model : "unpriced-test-model")

        let report = fixture.report(rows: [priced, unpriced])
        let entry = try #require(report.data.first)
        #expect(entry.totalTokens == 300_020)
        #expect(entry.costUSD == 2.5)
        #expect(entry.modelBreakdowns?.first?.costUSD == 2.5)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.coverageCounts.priced == 1)
        #expect(entry.coverageCounts.unpriced == 1)
        #expect(entry.coverageCounts.coverageRatio == 0.5)
        #expect(report.summary?.totalCostUSD == 2.5)
        #expect(report.hourly.compactMap(\.costUSD).reduce(0, +) == 2.5)
        #expect(report.quotaSlices.compactMap(\.costUSD).reduce(0, +) == 2.5)
        #expect(report.quotaSlices.contains { !$0.costIsComplete })
    }

    @Test
    func `canonical mixed pricing retains list price estimates`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let rows = [
            fixture.row(index: 0),
            fixture.row(index: 1, pricingModel: "unpriced-test-model"),
        ]

        let report = fixture.report(rows: rows)
        let entry = try #require(report.data.first)
        let cost = try #require(entry.costUSD)
        // 120K uncached input + 30K cached input + 10 output at the bundled mini rates.
        #expect(abs(cost - 0.092295) < 0.000000001)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(report.summary?.totalCostUSD == cost)
        #expect(report.hourly.compactMap(\.costUSD).reduce(0, +) == cost)
        #expect(report.quotaSlices.compactMap(\.costUSD).reduce(0, +) == cost)
    }

    @Test
    func `authoritative dollars survive incomplete token pricing`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let rows = [
            fixture.row(index: 0, knownCostNanos: 2_500_000_000),
            fixture.row(index: 1, knownCostNanos: 3_250_000_000, unpricedTokens: 150_010),
        ]

        let report = fixture.report(rows: rows)
        let entry = try #require(report.data.first)
        #expect(entry.costUSD == 5.75)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.coverageCounts.priced == 1)
        #expect(entry.coverageCounts.unpriced == 1)
        #expect(report.summary?.totalCostUSD == 5.75)
        #expect(report.hourly.compactMap(\.costUSD).reduce(0, +) == 5.75)
        #expect(report.quotaSlices.compactMap(\.costUSD).reduce(0, +) == 5.75)
        #expect(report.quotaSlices.contains { !$0.costIsComplete })
    }

    @Test
    func `mixed models retain unpriced coverage beside priced dollars`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let rows = [
            fixture.row(index: 0, knownCostNanos: 2_500_000_000),
            fixture.row(index: 1, model: "unpriced-test-model"),
        ]

        let report = fixture.report(rows: rows)
        let entry = try #require(report.data.first)
        #expect(entry.totalTokens == 300_020)
        #expect(entry.costUSD == 2.5)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.coverageCounts.priced == 1)
        #expect(entry.coverageCounts.unpriced == 1)
        #expect(entry.modelBreakdowns?.filter { $0.costUSD == nil }.count == 1)
        #expect(report.summary?.totalCostUSD == 2.5)
        #expect(report.quotaSlices.compactMap(\.costUSD).reduce(0, +) == 2.5)
    }

    @Test
    func `partial model coverage counts each canonical row`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let rows = [
            fixture.row(index: 0, knownCostNanos: 2_500_000_000),
            fixture.row(index: 1, pricingModel: "unpriced-test-model"),
            fixture.row(index: 2, pricingModel: "unpriced-test-model"),
        ]

        let report = fixture.report(rows: rows)
        let entry = try #require(report.data.first)
        #expect(entry.costUSD == 2.5)
        #expect(entry.totalTokens == 450_030)
        #expect(entry.pricedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 2)
        #expect(entry.coverageCounts.priced == 1)
        #expect(entry.coverageCounts.unpriced == 2)
        #expect(entry.coverageCounts.total == 3)
        #expect(report.quotaSlices.compactMap(\.costUSD).reduce(0, +) == 2.5)
    }

    @Test
    func `contradictory canonical rows do not gain a priced subtotal`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let rows = [
            fixture.row(index: 0, knownCostNanos: 2_500_000_000),
            fixture.row(index: 1, pricingModel: "unpriced-test-model"),
        ]
        let report = fixture.report(
            rows: rows,
            days: [fixture.dayKey: [fixture.model: [200_000, 60000, 20]]])

        #expect(report.data.first?.costUSD == nil)
        #expect(report.data.first?.pricedRequestCount == 0)
        #expect(report.data.first?.unpricedRequestCount == 1)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(report.quotaSlices.isEmpty)
    }

    @Test
    func `unstable estimated rows do not gain a priced subtotal`() throws {
        let fixture = try Fixture()
        defer { fixture.environment.cleanup() }
        let unstable = fixture.row(index: 0, hasStableEventIndex: false)
        let unpriced = fixture.row(index: 1, pricingModel: "unpriced-test-model")
        let report = fixture.report(rows: [unstable, unpriced])

        #expect(report.data.first?.costUSD == nil)
        #expect(report.data.first?.pricedRequestCount == 0)
        #expect(report.data.first?.unpricedRequestCount == 1)
        #expect(report.summary?.totalCostUSD == nil)
        #expect(report.quotaSlices.allSatisfy { $0.costUSD == nil })
    }

    private struct Fixture {
        let environment: CostUsageTestEnvironment
        let day: Date
        let range: CostUsageScanner.CostUsageDayRange
        let model = "gpt-5.4-mini"

        var dayKey: String {
            self.range.sinceKey
        }

        init() throws {
            let environment = try CostUsageTestEnvironment()
            self.environment = environment
            self.day = try environment.makeLocalNoon(year: 2026, month: 8, day: 11)
            self.range = CostUsageScanner.CostUsageDayRange(since: self.day, until: self.day)
        }

        func row(
            index: Int,
            hasStableEventIndex: Bool = true,
            model: String? = nil,
            knownCostNanos: Int64? = nil,
            unpricedTokens: Int? = nil,
            pricingModel: String? = nil) -> CostUsageScanner.CodexUsageRow
        {
            CostUsageScanner.CodexUsageRow(
                day: self.dayKey,
                model: model ?? self.model,
                turnID: "test-turn-\(index)",
                eventIndex: hasStableEventIndex ? index : nil,
                timestampUnixMs: Int64(self.day.timeIntervalSince1970 * 1000) + Int64(index * 1000),
                input: 150_000,
                cached: 30000,
                output: 10,
                knownCostNanos: knownCostNanos,
                unpricedTokens: unpricedTokens,
                pricingModel: pricingModel)
        }

        func report(
            rows: [CostUsageScanner.CodexUsageRow],
            days: [String: [String: [Int]]]? = nil) -> CostUsageDailyReport
        {
            let usage = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 1,
                days: days ?? CostUsageScanner.codexFileDays(rows: rows),
                parsedBytes: 1,
                codexRows: rows,
                codexScanComplete: true)
            var cache = CostUsageCache()
            cache.files = [self.environment.root.appendingPathComponent("partial-pricing.jsonl").path: usage]
            cache.days = usage.days
            return CostUsageScanner.buildCodexReportFromCache(
                cache: cache,
                range: self.range,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        }
    }
}
