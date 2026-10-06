import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageCodexRequestLedgerTests {
    @Test(arguments: [
        (Int64.min, Int64.max, false),
        (Int64.min, 0, false),
        (Int64.min, Int64.min + 5000, true),
        (Int64.min, Int64.min + 5001, false),
        (Int64.max, Int64.max - 5000, true),
        (Int64.max, Int64.max - 5001, false),
    ])
    func `mirror window handles extreme timestamps without overflowing`(_ scenario: (Int64, Int64, Bool)) {
        let first = CostUsageScanner.CodexNearMirror(key: "synthetic-turn", timestampMs: scenario.0, total: nil)
        let second = CostUsageScanner.CodexNearMirror(key: "synthetic-turn", timestampMs: scenario.1, total: nil)
        #expect(first.isWithinWindow(of: second) == scenario.2)
        #expect(second.isWithinWindow(of: first) == scenario.2)
    }

    /// After a resume, Codex's token_count counter can run behind the thread counter while both events still describe
    /// the same response a few milliseconds apart. Adjacent same-turn observations with identical usage inside the
    /// mirror window are one request; beyond it they stay distinct.
    @Test(arguments: [false, true], [2, 4900, 5000, 5001, 5100])
    func `adjacent offset counters pair only inside the mirror window`(ledgerFirst: Bool, gapMs: Int) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: gapMs)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44],
            turnTotal: [500, 100, 50, 20])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [860, 172, 86, 34])
        let result = try Self.parse(Self.header() + (ledgerFirst ? [ledger, legacy] : [legacy, ledger]), env: env)
        let paired = gapMs <= 5000
        #expect(result.rows.count == (paired ? 1 : 2))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (paired ? 110 : 220))
        #expect(result.rows.compactMap(\.responseID) == ["one"])
    }

    @Test(arguments: [false, true])
    func `adjacent equal usage from another turn remains distinct inside the mirror window`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44])
        let legacy: [String: Any] = [
            "type": "event_msg", "timestamp": ledgerFirst ? later : Self.timestampA, "payload": [
                "type": "token_count", "turn_id": "other-turn", "info": [
                    "last_token_usage": Self.tokens(usage), "total_token_usage": Self.tokens([860, 172, 86, 34]),
                ],
            ],
        ]
        let result = try Self.parse(Self.header() + (ledgerFirst ? [ledger, legacy] : [legacy, ledger]), env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// The pending observation is persisted, so a mirror appended after a refresh still pairs with it.
    @Test(arguments: [false, true])
    func `offset counter mirrors pair across an incremental refresh`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 3)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [3000, 600, 300, 120],
            turnTotal: [2000, 400, 200, 80])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [1500, 300, 150, 60])
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "offset-mirror.jsonl",
            contents: env.jsonl(Self.header() + [ledgerFirst ? ledger : legacy]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: end, options: options)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([ledgerFirst ? legacy : ledger]).utf8))
        try handle.close()
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: start,
            until: end,
            now: end.addingTimeInterval(1),
            options: options)
        let rows = try #require(CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar)
            .files[file.path]?.codexRows)
        #expect(rows.count == 1)
        #expect(rows.compactMap(\.responseID) == ["one"])
        #expect(report.summary?.totalTokens == 1100)
    }

    /// Revision 8 stored the offset-counter mirror as a second row. The revision 9 reparse drops it and keeps the
    /// ledger row's saved pricing, without rebuilding the store.
    @Test(arguments: [false, true])
    func `revision 8 duplicate mirror rows are removed by the reparse`(unpriced: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let mirrorAt = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "duplicate-mirror.jsonl",
            contents: env.jsonl(Self.header() + [
                Self.record(id: "one", usage: usage, total: [3000, 600, 300, 120], turnTotal: [2000, 400, 200, 80]),
                Self.legacy(timestamp: mirrorAt, usage: usage, total: [1500, 300, 150, 60]),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func report(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: now, options: options)
        }
        func load() -> CostUsageFileUsage? {
            CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar).files[file.path]
        }
        #expect(report(end).summary?.totalTokens == 1100)

        // Recreate what revision 8 saved: the ledger row with Priority evidence plus the unpaired mirror row.
        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        var usageFile = try #require(stored.files[file.path])
        var ledger = try #require(usageFile.codexRows?.first)
        ledger.pricingMode = "priority"
        let duplicate = CostUsageScanner.CodexUsageRow(
            day: ledger.day,
            model: ledger.model,
            rawModel: ledger.rawModel,
            turnID: ledger.turnID,
            eventIndex: (ledger.eventIndex ?? 0) + 1,
            timestampUnixMs: Int64((start.timeIntervalSince1970 * 1000).rounded()) + 2,
            input: ledger.input,
            cached: ledger.cached,
            output: ledger.output,
            reasoning: ledger.reasoning,
            pricingModel: ledger.pricingModel,
            pricingMode: "standard")
        var duplicateRow = duplicate
        if unpriced {
            // A fully marked file has no saved price to retain; its rows must stay unknown, not current-priced.
            ledger.unpricedTokens = 1100
            duplicateRow.unpricedTokens = 1100
            options.maxCodexScanBytesPerRefresh = usageFile.size / 2
        }
        usageFile.codexRows = [ledger, duplicateRow]
        usageFile.codexParserRevision = 8
        stored.files[file.path] = usageFile
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored, calendar: calendar)
            .catchUpRequired)
        #expect(load()?.codexRows?.count == 2)

        var migrated: CostUsageFileUsage?
        for pass in 1...20 {
            _ = report(end.addingTimeInterval(Double(pass)))
            migrated = load()
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true { break }
        }
        let rows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(rows.count == 1)
        #expect(rows.first?.responseID == "one")
        // Saved Priority evidence is retained for priced rows; an unpriced row has no price to carry.
        if !unpriced {
            #expect(rows.first?.pricingMode == "priority")
        }
        #expect(rows.first?.unpricedTokens == (unpriced ? 1100 : nil))
        let migratedReport = report(end.addingTimeInterval(30))
        #expect(migratedReport.summary?.totalTokens == 1100)
        if unpriced {
            #expect(migratedReport.summary?.totalCostUSD == nil)
        }
    }

    /// Real token_count payloads carry no turn_id; the active task supplies it, and a new task ends adjacency.
    @Test(arguments: [false, true])
    func `real token count shape pairs within its task only`(taskBetween: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2)
        var lines = Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: usage, total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
        ]
        if taskBetween { lines.append(Self.taskStarted("synthetic-turn")) }
        lines.append(Self.realLegacy(timestamp: later, usage: usage, total: [860, 172, 86, 34]))
        let result = try Self.parse(lines, env: env)
        #expect(result.rows.count == (taskBetween ? 2 : 1))
        #expect(result.rows.compactMap(\.responseID) == ["one"])
    }

    /// After a tool runs, Codex writes the token_count long after its ledger record. Once a pair established the
    /// counter offset, a later ledger-first pair with the same offset is one request; a different offset is not.
    @Test(arguments: [true, false])
    func `far ledger first mirrors pair when their counter offset matches`(sameOffset: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let farLater = try Self.timestamp(Self.timestampA, plusMilliseconds: 30000)
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10),
                usage: [60, 20, 6, 3],
                total: [1160, 240, 116, 47],
                turnTotal: [560, 120, 56, 23]),
            Self.realLegacy(
                timestamp: farLater,
                usage: [60, 20, 6, 3],
                total: sameOffset ? [920, 192, 92, 37] : [925, 192, 92, 37]),
        ], env: env)
        #expect(result.rows.count == (sameOffset ? 2 : 3))
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == (sameOffset ? 176 : 242))
        #expect(result.rows.compactMap(\.responseID) == ["one", "two"])
    }

    /// Offset pairing applies only when the ledger record comes first; a token_count followed much later by a ledger
    /// record of equal size stays two requests even when their offset matches the learned one.
    @Test
    func `far legacy first observations stay distinct even with the learned offset`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10),
                usage: [60, 20, 6, 3],
                total: [920, 192, 92, 37]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 30000),
                usage: [60, 20, 6, 3],
                total: [1160, 240, 116, 47],
                turnTotal: [560, 120, 56, 23]),
        ], env: env)
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 242)
    }

    /// A legacy-only request is part of the thread counter, so an owned record of equal size that follows it is a
    /// different request even when the offset from an earlier pair is known.
    @Test
    func `legacy only request before an equal owned request stays distinct`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 20000),
                usage: [50, 10, 5, 2],
                total: [910, 182, 91, 36]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 50000),
                usage: [50, 10, 5, 2],
                total: [1200, 240, 120, 48],
                turnTotal: [600, 120, 60, 24]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 50002),
                usage: [50, 10, 5, 2],
                total: [960, 192, 96, 38]),
        ], env: env)
        #expect(result.rows.count == 3)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// A resumed session and a counted bare usage line both separate observations, so they cannot be one request.
    @Test(arguments: [false, true], ["resume", "bare usage"])
    func `session resume or bare usage between observations keeps them distinct`(
        ledgerFirst: Bool,
        separator: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let between = try Self.timestamp(Self.timestampA, plusMilliseconds: 1000)
        let later = try Self.timestamp(Self.timestampA, plusMilliseconds: 2000)
        let ledger = Self.record(
            id: "one",
            timestamp: ledgerFirst ? Self.timestampA : later,
            usage: usage,
            total: [1100, 220, 110, 44],
            turnTotal: [500, 100, 50, 20])
        let legacy = Self.legacy(
            timestamp: ledgerFirst ? later : Self.timestampA,
            usage: usage,
            total: [860, 172, 86, 34])
        let separatorLine: [String: Any] = separator == "resume"
            ? ["type": "session_meta", "timestamp": between, "payload": ["id": "synthetic-thread"]]
            : ["timestamp": between, "usage": ["prompt_tokens": 10, "completion_tokens": 1]]
        let result = try Self.parse(
            Self.header() + (ledgerFirst ? [ledger, separatorLine, legacy] : [legacy, separatorLine, ledger]),
            env: env)
        let bareTokens = separator == "bare usage" ? 11 : 0
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220 + bareTokens)
    }

    /// A replayed response is already counted; it must not claim a different legacy request of equal size nearby.
    @Test(arguments: [false, true])
    func `a replay does not pair with a different legacy request inside the mirror window`(replayFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let usage = [100, 20, 10, 4]
        let replay = try Self.record(
            id: "one",
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: replayFirst ? 4000 : 4500),
            usage: usage,
            total: [1100, 220, 110, 44],
            turnTotal: [500, 100, 50, 20])
        let laterRequest = try Self.realLegacy(
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: replayFirst ? 4500 : 4000),
            usage: usage,
            total: [960, 192, 96, 38])
        let result = try Self.parse(Self.header() + [
            Self.taskStarted("synthetic-turn"),
            Self.record(id: "one", usage: usage, total: [1100, 220, 110, 44], turnTotal: [500, 100, 50, 20]),
            Self.realLegacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2),
                usage: usage,
                total: [860, 172, 86, 34]),
        ] + (replayFirst ? [replay, laterRequest] : [laterRequest, replay]), env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    /// Subagent observations are buffered and replayed in order, but a bare usage line is counted when it is read.
    /// Once a file has counted bare usage, only exact mirror keys pair, as before the near-mirror rules.
    @Test
    func `bare usage keeps buffered subagent observations distinct`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        header[0]["payload"] = [
            "id": "synthetic-thread", "session_id": "execution-session",
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
        ]
        var ledger = Self.record(id: "one", usage: [100, 20, 10, 4], total: [1100, 220, 110, 44])
        var payload = try #require(ledger["payload"] as? [String: Any])
        payload["session_id"] = "execution-session"
        ledger["payload"] = payload
        let result = try Self.parse(header + [
            ledger,
            [
                "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
                "usage": ["prompt_tokens": 10, "completion_tokens": 1],
            ],
            Self.legacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2000),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
        ], env: env)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 231)
    }

    /// A bounded pass that stops after a bare usage line resumes with the same pairing rule as a full parse. In a
    /// subagent file the ledger record is still buffered, so the state saved after the bare line is otherwise empty.
    @Test(arguments: [true, false])
    func `bare usage gives the same pairing across a bounded pass`(subagent: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        let bare: [String: Any] = try [
            "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
            "usage": ["prompt_tokens": 10, "completion_tokens": 1],
        ]
        let usage = [100, 20, 10, 4]
        let legacy = try Self.legacy(
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2000),
            usage: usage,
            total: [860, 172, 86, 34])
        let prefix: String
        let suffix: String
        if subagent {
            header[0]["payload"] = [
                "id": "synthetic-thread",
                "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]],
            ]
            prefix = try env.jsonl(header + [Self.record(id: "one", usage: usage, total: [1100, 220, 110, 44]), bare])
            suffix = try env.jsonl([legacy])
        } else {
            // Read in order, the bare line precedes both observations and does not separate them.
            prefix = try env.jsonl(header + [bare])
            suffix = try env.jsonl([
                Self.record(
                    id: "one",
                    timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1998),
                    usage: usage,
                    total: [1100, 220, 110, 44]),
                legacy,
            ])
        }
        let file = env.root.appendingPathComponent("bounded-bare.jsonl")
        try (prefix + suffix).write(to: file, atomically: false, encoding: .utf8)
        let day = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: calendar)
        let partial = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, maxBytesToRead: Int64(prefix.utf8.count))
        let resumed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: partial.parsedBytes,
            initialSessionID: partial.sessionId,
            initialCodexUsageRowIndex: partial.nextUsageRowIndex,
            initialBufferedSubagentLines: partial.bufferedSubagentLines,
            initialJSONLResumeState: partial.jsonlResumeState,
            initialRequestLedgerState: partial.requestLedgerState,
            initialRequestLedgerRows: partial.rows)
        let cold = try CostUsageScanner.parseCodexFileCancellable(fileURL: file, range: range)
        let expected = subagent ? 231 : 121
        #expect((partial.rows + resumed.rows).reduce(0) { $0 + $1.input + $1.output } == expected)
        #expect(cold.rows.reduce(0) { $0 + $1.input + $1.output } == expected)
    }

    /// A fork processes lines when read even while its parent is unresolved, so a bare line there separates the first
    /// observations without disabling near pairing. A parse that resolves the parent later matches a cold parse.
    @Test
    func `fork bare usage keeps later drifted pairs when the parent resolves late`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var header = Self.header()
        header[0]["payload"] = ["id": "synthetic-thread", "forked_from_id": "parent", "timestamp": Self.timestampA]
        let body: [[String: Any]] = try [
            Self.record(
                id: "one",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
                usage: [100, 20, 10, 4],
                total: [1100, 220, 110, 44],
                turnTotal: [500, 100, 50, 20]),
            [
                "timestamp": Self.timestamp(Self.timestampA, plusMilliseconds: 1500),
                "usage": ["prompt_tokens": 10, "completion_tokens": 1],
            ],
            Self.legacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 2000),
                usage: [100, 20, 10, 4],
                total: [860, 172, 86, 34]),
            Self.record(
                id: "two",
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10000),
                usage: [60, 20, 6, 3],
                total: [1160, 240, 116, 47],
                turnTotal: [560, 120, 56, 23]),
            Self.legacy(
                timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 10002),
                usage: [60, 20, 6, 3],
                total: [920, 192, 92, 37]),
        ]
        let file = env.root.appendingPathComponent("fork-late.jsonl")
        try env.jsonl(header + body).write(to: file, atomically: false, encoding: .utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let range = CostUsageScanner.CostUsageDayRange(since: start, until: end, calendar: calendar)
        // The parent prefix ends where the first token_count counter continues.
        let inherited = CostUsageCodexTotals(input: 760, cached: 152, output: 76)
        let resolved: (String, String) throws -> CostUsageScanner.CodexForkBaseline = { _, _ in .resolved(inherited) }
        let unresolved: (String, String) throws -> CostUsageScanner.CodexForkBaseline = { _, _ in .unresolved }
        func tokens(_ rows: [CostUsageScanner.CodexUsageRow]) -> Int {
            rows.reduce(0) { $0 + $1.input + $1.output }
        }
        let cold = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, inheritedTotalsResolver: resolved)
        let pass1 = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file, range: range, inheritedTotalsResolver: unresolved)
        let pass2 = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: file,
            range: range,
            startOffset: pass1.parsedBytes,
            initialModel: pass1.lastModel,
            initialSessionID: pass1.sessionId,
            initialTotals: pass1.lastCountedTotals,
            initialRawTotalsBaseline: pass1.lastRawTotalsBaseline,
            initialRawTotalsWatermark: pass1.lastRawTotalsWatermark,
            initialSeenRawTotals: pass1.seenRawTotals,
            initialHasDivergentTotals: pass1.hasDivergentTotals,
            initialHasInterleavedTotals: pass1.hasInterleavedTotals,
            initialCodexTurnID: pass1.lastCodexTurnID,
            initialCodexUsageRowIndex: pass1.nextUsageRowIndex,
            initialBufferedSubagentLines: pass1.bufferedSubagentLines,
            initialBufferedUnresolvedForkLines: pass1.bufferedUnresolvedForkLines,
            initialJSONLResumeState: pass1.jsonlResumeState,
            initialRequestLedgerState: pass1.requestLedgerState,
            initialRequestLedgerRows: pass1.rows,
            inheritedTotalsResolver: resolved)
        let kept = pass1.rows.filter { row in
            row.eventIndex.map { !pass2.replacedLegacyRowIndices.contains($0) } ?? true
        }
        #expect(pass1.bufferedUnresolvedForkLines?.isEmpty == false)
        #expect(tokens(cold.rows) == 297)
        #expect(tokens(kept + pass2.rows) == 297)
    }

    /// Near pairing needs the same known turn; files without turn evidence keep exact pairing only.
    /// After an exact pair, a legacy-only and a ledger-only request of equal size can land milliseconds apart. The
    /// later counter advances by both requests, so the two are distinct even inside the window, including through
    /// the revision 8 reparse.
    @Test(arguments: [false, true])
    func `a counter that advances past its usage keeps equal requests distinct`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [100, 20, 10, 4]
        let first = try Self.timestamp(Self.timestampA, plusMilliseconds: 1000)
        let second = try Self.timestamp(Self.timestampA, plusMilliseconds: 1002)
        let onlyLedger = Self.record(
            id: "two", timestamp: ledgerFirst ? first : second, usage: usage, total: ledgerFirst
                ? [200, 40, 20, 8] : [300, 60, 30, 12])
        let onlyLegacy = Self.legacy(
            timestamp: ledgerFirst ? second : first, usage: usage, total: ledgerFirst
                ? [300, 60, 30, 12] : [200, 40, 20, 8])
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "continuity.jsonl",
            contents: env.jsonl(Self.header() + [
                Self.record(id: "one", usage: usage, total: usage),
                Self.legacy(timestamp: Self.timestampA, usage: usage, total: usage),
            ] + (ledgerFirst ? [onlyLedger, onlyLegacy] : [onlyLegacy, onlyLedger])))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func report(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: now, options: options)
        }
        func load() -> CostUsageFileUsage? {
            CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar).files[file.path]
        }
        #expect(report(end).summary?.totalTokens == 330)
        #expect(load()?.codexRows?.count == 3)

        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        var usageFile = try #require(stored.files[file.path])
        usageFile.codexParserRevision = 8
        stored.files[file.path] = usageFile
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored, calendar: calendar)
            .catchUpRequired)
        var migrated: CostUsageFileUsage?
        for pass in 1...20 {
            _ = report(end.addingTimeInterval(Double(pass)))
            migrated = load()
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true { break }
        }
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(migrated?.codexRows?.count == 3)
        #expect(report(end.addingTimeInterval(30)).summary?.totalTokens == 330)
    }

    /// Two requests can share a saved-pricing key. If one was saved as unknown, the key cannot prove which request
    /// its price belongs to, so the revision 9 reparse prices neither.
    @Test(arguments: [false, true])
    func `revision 8 reparse keeps a marker that shares its pricing key with a priced request`(bounded: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: Self.timestampA))
        let end = try #require(ISO8601DateFormatter().date(from: Self.timestampC))
        let usage = [1000, 200, 100, 40]
        let file = try env.writeCodexSessionFile(
            day: start,
            filename: "colliding-keys.jsonl",
            contents: env.jsonl(Self.header() + [
                Self.record(id: "one", usage: usage, total: [1000, 200, 100, 40]),
                Self.record(id: "two", usage: usage, total: [2000, 400, 200, 80]),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        func report(_ now: Date) -> CostUsageDailyReport {
            CostUsageScanner.loadDailyReport(provider: .codex, since: start, until: end, now: now, options: options)
        }
        #expect(report(end).summary?.totalTokens == 2200)

        var stored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: calendar)
        var usageFile = try #require(stored.files[file.path])
        var rows = try #require(usageFile.codexRows)
        try #require(rows.count == 2)
        #expect(Set(rows.compactMap(CostUsageScanner.CodexSourcePricingKey.init)).count == 1)
        rows[0].pricingMode = "priority"
        rows[1].unpricedTokens = 1100
        usageFile.codexRows = rows
        usageFile.codexParserRevision = 8
        stored.files[file.path] = usageFile
        #expect(!CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: stored, calendar: calendar)
            .catchUpRequired)
        if bounded {
            options.maxCodexScanBytesPerRefresh = usageFile.size / 2
        }

        var migrated: CostUsageFileUsage?
        for pass in 1...20 {
            _ = report(end.addingTimeInterval(Double(pass)))
            migrated = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: calendar)
                .files[file.path]
            if migrated?.hasCurrentCodexParser == true, migrated?.codexScanComplete == true { break }
        }
        let migratedRows = try #require(migrated?.codexRows)
        #expect(migrated?.hasCurrentCodexParser == true)
        #expect(migratedRows.map(\.unpricedTokens) == [1100, 1100])
        #expect(report(end.addingTimeInterval(30)).summary?.totalCostUSD == nil)
    }

    @Test(arguments: [false, true])
    func `equal usage without a known turn remains distinct inside the mirror window`(ledgerFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var ledger = Self.record(id: "one", usage: [100, 20, 10, 4], total: [100, 20, 10, 4])
        var payload = try #require(ledger["payload"] as? [String: Any])
        payload["turn_id"] = nil
        ledger["payload"] = payload
        let legacy = try Self.realLegacy(
            timestamp: Self.timestamp(Self.timestampA, plusMilliseconds: 1000),
            usage: [100, 20, 10, 4],
            total: [200, 40, 20, 8])
        let result = try Self.parse([Self.header()[0]] + (ledgerFirst ? [ledger, legacy] : [legacy, ledger]), env: env)
        #expect(result.rows.count == 2)
        #expect(result.rows.reduce(0) { $0 + $1.input + $1.output } == 220)
    }

    static func taskStarted(_ turnID: String) -> [String: Any] {
        ["type": "event_msg", "timestamp": self.timestampA, "payload": ["type": "task_started", "turn_id": turnID]]
    }

    /// The token_count shape Codex writes: no turn_id in the payload.
    static func realLegacy(timestamp: String, usage: [Int], total: [Int]) -> [String: Any] {
        ["type": "event_msg", "timestamp": timestamp, "payload": [
            "type": "token_count", "info": [
                "last_token_usage": self.tokens(usage), "total_token_usage": self.tokens(total),
            ],
        ]]
    }
}
