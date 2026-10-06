import Foundation

extension CostUsageScanner {
    static func canResumeCodexForkAccounting(
        _ cached: CostUsageFileUsage,
        context: CodexFileScanContext) throws -> Bool
    {
        guard let parentID = cached.forkedFromId,
              let saved = cached.codexForkAccountingState,
              !saved.metadata.isSubagentThread,
              saved.metadata.sessionId == cached.sessionId,
              saved.metadata.forkedFromId == parentID,
              let dependency = cached.forkBaselineDependencyKey
        else { return false }
        return try dependency == context.resources.inheritedResolver.currentDependencyKey(for: parentID)
    }

    /// Missing-parent forks stay out of priced totals. Count them as unmetered so Spend
    /// coverage can show the gap instead of silently dropping the session.
    static func unresolvedForkUnmeteredCounts(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: Int]
    {
        var counts: [String: Int] = [:]
        for usage in cache.files.values {
            guard self.isUnresolvedMissingParentFork(usage),
                  !self.codexFileHasBilledTokens(usage)
            else { continue }
            let unixMs = usage.codexSession?.startedAtUnixMs
                ?? usage.codexSession?.latestActivityUnixMs
                ?? usage.mtimeUnixMs
            guard unixMs > 0 else { continue }
            let dayKey = CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000),
                calendar: range.calendar)
            guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.sinceKey, until: range.untilKey)
            else { continue }
            counts[dayKey, default: 0] += 1
        }
        return counts
    }

    static func isUnresolvedMissingParentFork(_ usage: CostUsageFileUsage) -> Bool {
        usage.forkedFromId != nil
            && (usage.forkBaselineDependencyKey.map(self.codexDependencyIsMissing) ?? true)
    }

    static func codexDependencyIsMissing(_ key: String) -> Bool {
        key.hasPrefix("missing|") || key.contains("|inherited|missing|")
    }

    static func codexFileHasBilledTokens(_ usage: CostUsageFileUsage) -> Bool {
        if (usage.codexRows ?? []).contains(where: { $0.input > 0 || $0.cached > 0 || $0.output > 0 }) {
            return true
        }
        return usage.days.values.contains { models in
            models.values.contains { packed in packed.contains { $0 > 0 } }
        }
    }

    struct CodexReportDayPricingContext {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]]
        var unresolvedRowGroups: Set<CodexDayModelKey>
        var modeOwnershipMismatchGroups: Set<CodexDayModelKey>
        var requestPricingEvidenceGroups: Set<CodexDayModelKey>
        var incompletePricingEvidenceGroups: Set<CodexDayModelKey>
        var authoritativeCostEvidenceGroups: Set<CodexDayModelKey>
        var priorityTurns: [String: CodexPriorityTurnMetadata]
        var modelsDevCatalog: ModelsDevCatalog
        var modelsDevCacheRoot: URL?
        var customPricing: CostUsageCustomPricing
        var pricingResolver: CostUsagePricing.CodexResolver
    }

    static func unmeteredForkReportEntry(day: String, unmetered: Int) -> CostUsageDailyReport.Entry? {
        guard unmetered > 0 else { return nil }
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            costUSD: nil,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unmeteredRequestCount: unmetered)
    }

    static func makeCodexBilledDayEntry(
        day: String,
        models: [String: [Int]],
        unmetered: Int,
        pricing: CodexReportDayPricingContext) -> CostUsageDailyReport.Entry?
    {
        let modelNames = models.keys
            .filter { OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: $0) }
            .sorted()
        if modelNames.isEmpty {
            return Self.unmeteredForkReportEntry(day: day, unmetered: unmetered)
        }
        var dayInput = CostUsageDailyReport.OptionalCountAccumulator(0)
        var dayCacheRead = CostUsageDailyReport.OptionalCountAccumulator(0)
        var dayOutput = CostUsageDailyReport.OptionalCountAccumulator(0)
        var dayReasoning = CostUsageDailyReport.OptionalCountAccumulator(0)
        var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
        var dayCost: Double = 0
        var dayCostSeen = false
        var coverage = CostUsageCoverageCounts()

        for model in modelNames {
            guard OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: model) else { continue }
            let packed = models[model] ?? [0, 0, 0]
            let input = packed[safe: 0] ?? 0
            let cached = packed[safe: 1] ?? 0
            let output = packed[safe: 2] ?? 0
            let totalTokens = CheckedSum.integers([input, output])
            let rows = pricing.rowsByDayModel[day]?[model] ?? []
            let reasoning = CheckedSum.integers(rows.compactMap(\.reasoning))

            dayInput.add(input)
            dayCacheRead.add(cached)
            dayOutput.add(output)
            for row in rows {
                dayReasoning.add(row.reasoning)
            }

            let rowCost = rows.isEmpty ? nil : Self.codexRowCostBreakdown(
                rows: rows,
                priorityTurns: pricing.priorityTurns,
                modelsDevCatalog: pricing.modelsDevCatalog,
                modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                customPricing: pricing.customPricing,
                pricingResolver: pricing.pricingResolver)
            let group = CodexDayModelKey(day: day, model: model)
            // A combined token counter can overflow while each source class and its supplied
            // monetary amount remain valid. Never replace authoritative dollars with repricing.
            let authoritativeOverflowCost = totalTokens == nil && !rows.isEmpty
                && rows.allSatisfy { $0.knownCostNanos != nil && ($0.unpricedTokens ?? 0) == 0 }
                && CheckedSum.integers(rows.map(\.input)) == input
                && CheckedSum.integers(rows.map(\.cached)) == cached
                && CheckedSum.integers(rows.map(\.output)) == output
            let rowTokens = rowCost.flatMap { CheckedSum.integers([$0.standardTokens, $0.priorityTokens]) }
            let rowAccountingIsTrusted = !pricing.unresolvedRowGroups.contains(group)
                && !pricing.modeOwnershipMismatchGroups.contains(group)
                && (authoritativeOverflowCost
                    || (!rows.isEmpty && rowCost?.hasUnstableTokenRows == false
                        && rowCost?.hasTokenOverflow == false && totalTokens != nil && rowTokens == totalTokens))
            let rowCostIsTrusted = rowAccountingIsTrusted && rowCost?.hasIncompletePricing == false
            let aggregateCost = pricing.requestPricingEvidenceGroups.contains(group)
                || pricing.incompletePricingEvidenceGroups.contains(group)
                || (pricing.unresolvedRowGroups.contains(group)
                    && pricing.authoritativeCostEvidenceGroups.contains(group))
                || rowCost?.hasIncompletePricing == true
                ? nil
                : CostUsagePricing.codexCostUSD(
                    aggregate: true,
                    model: model,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    outputTokens: output,
                    modelsDevCatalog: pricing.modelsDevCatalog,
                    modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                    customPricing: pricing.customPricing,
                    pricingResolver: pricing.pricingResolver)
            // Missing rates do not invalidate canonical ownership of the other requests. Keep
            // their proven subtotal, using the same row evidence as the timestamped buckets.
            let pricedRows = rowAccountingIsTrusted ? Self.codexPricedRows(rows: rows, pricing: pricing) : nil
            let cost = rowCostIsTrusted
                ? rowCost?.totalCostUSD ?? aggregateCost : pricedRows?.costUSD ?? aggregateCost
            if let pricedRows {
                coverage.merge(pricedRows.coverage)
            } else if let cost, cost.isFinite, cost >= 0 {
                // Without canonical request boundaries, one known model aggregate is the
                // conservative coverage unit rather than an invented request count.
                coverage.priced += 1
            } else if (totalTokens ?? 1) > 0 {
                coverage.unpriced += 1
            }
            let hasModeSplit = rowCostIsTrusted && rowCost?.hasModeSplit == true
            breakdown.append(
                CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: cost,
                    totalTokens: totalTokens,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cached > 0 ? cached : nil,
                    reasoningTokens: reasoning.flatMap { $0 > 0 ? $0 : nil },
                    standardCostUSD: hasModeSplit ? rowCost?.optionalStandardCostUSD : nil,
                    priorityCostUSD: hasModeSplit ? rowCost?.optionalPriorityCostUSD : nil,
                    standardTokens: hasModeSplit ? rowCost?.optionalStandardTokens : nil,
                    priorityTokens: hasModeSplit ? rowCost?.optionalPriorityTokens : nil))
            if let cost {
                dayCost += cost
                dayCostSeen = true
            }
        }

        var dayTokens = dayInput
        dayTokens.merge(dayOutput)
        let dayTotal = dayTokens.value
        let entryCost = dayCostSeen && dayCost.isFinite ? dayCost : nil
        return CostUsageDailyReport.Entry(
            date: day,
            inputTokens: dayInput.value,
            outputTokens: dayOutput.value,
            cacheReadTokens: dayCacheRead.value.flatMap { $0 > 0 ? $0 : nil },
            reasoningTokens: dayReasoning.value.flatMap { $0 > 0 ? $0 : nil },
            totalTokens: dayTotal,
            costUSD: entryCost,
            modelsUsed: modelNames,
            modelBreakdowns: Self.sortedModelBreakdowns(breakdown),
            unpricedRequestCount: coverage.unpriced,
            unmeteredRequestCount: unmetered,
            estimatedRequestCount: 0,
            pricedRequestCount: coverage.priced)
    }

    private struct CodexPricedRows {
        let costUSD: Double?
        let coverage: CostUsageCoverageCounts
    }

    private static func codexPricedRows(
        rows: [CodexUsageRow],
        pricing: CodexReportDayPricingContext) -> CodexPricedRows
    {
        var subtotal: Double?
        var costIsValid = true
        var coverage = CostUsageCoverageCounts()
        for row in rows {
            guard row.input > 0 || row.cached > 0 || row.output > 0 || row.knownCostNanos != nil else { continue }
            let hasUnpricedTokens = (row.unpricedTokens ?? 0) > 0
            // Explicit dollars survive incomplete token pricing. Estimated dollars require
            // complete request evidence; the caller has already validated canonical ownership.
            let resolvedCost = row.knownCostNanos != nil || !hasUnpricedTokens
                ? Self.codexResolvedCostUSD(
                    for: row,
                    priorityTurns: pricing.priorityTurns,
                    modelsDevCatalog: pricing.modelsDevCatalog,
                    modelsDevCacheRoot: pricing.modelsDevCacheRoot,
                    customPricing: pricing.customPricing,
                    pricingResolver: pricing.pricingResolver) : nil
            let cost = resolvedCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if hasUnpricedTokens || cost == nil {
                coverage.unpriced += 1
            } else {
                coverage.priced += 1
            }
            if let cost {
                let sum = (subtotal ?? 0) + cost
                costIsValid = costIsValid && sum.isFinite
                subtotal = sum
            }
        }
        return CodexPricedRows(costUSD: costIsValid ? subtotal : nil, coverage: coverage)
    }
}

extension CostUsageFileUsage {
    func touchesCodexScanWindow(
        sinceKey: String,
        untilKey: String,
        calendar: Calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()) -> Bool
    {
        if self.days.keys.contains(where: {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }) {
            return true
        }

        // Billed days are empty for unresolved forks. Use the entire observed event span,
        // not just the start date: an old fork can contain current usage.
        let isIncompleteFork = self.hasBufferedCodexUnresolvedForkLines
            || CostUsageScanner.isUnresolvedMissingParentFork(self)
        guard isIncompleteFork else { return false }
        guard let first = self.codexSession?.startedAtUnixMs,
              let last = self.codexSession?.latestActivityUnixMs else { return true }
        let firstDay = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(first) / 1000), calendar: calendar)
        let lastDay = CostUsageScanner.CostUsageDayRange.dayKey(
            from: Date(timeIntervalSince1970: TimeInterval(last) / 1000), calendar: calendar)
        return firstDay <= untilKey && lastDay >= sinceKey
    }
}
