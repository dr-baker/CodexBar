import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in native menu screenshots, driven entirely inside an isolated synthetic test application.
@MainActor
final class MenuCardBackdropNativeProofTests: XCTestCase {
    func test_busyBackgroundInBothAppearances() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_BACKDROP_NATIVE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_BACKDROP_NATIVE_PROOF_DIR for isolated native backing proof.")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential, Keychain, and session isolation.") }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let application = NSApplication.shared
        guard application.delegate == nil else { return XCTFail("Requires a standalone test application.") }
        let previousAppearance = application.appearance
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Synthetic Menu Backing Proof"
        host.isReleasedWhenClosed = false
        let background = MenuBackdropProofBackground(frame: NSRect(x: 0, y: 0, width: 920, height: 760))
        host.contentView = background
        defer {
            host.close()
            application.appearance = previousAppearance
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        host.center()
        host.makeKeyAndOrderFront(nil)
        application.activate()

        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            application.appearance = appearance
            host.appearance = appearance
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let menu = Self.makeMenu()
            StatusMenuAppearance.pin(menu, to: appearance)
            let label = name == .darkAqua ? "dark" : "light"
            let capture = MenuBackdropProofCapture(menu: menu, directory: directory, label: label)
            let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated { capture.captureAndClose() }
            }
            let watchdog = Timer(timeInterval: 5, repeats: false) { _ in
                MainActor.assumeIsolated { capture.menu.cancelTracking() }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(watchdog, forMode: .common)
            defer {
                timer.invalidate()
                watchdog.invalidate()
                menu.cancelTracking()
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 210, y: background.bounds.maxY - 30), in: background)
            XCTAssertTrue(capture.completed, "Native menu did not reach its capture timer.")
            if let failure = capture.failure { throw failure }
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(label)-native-menu.png").path))
        }
    }

    private static func makeMenu() -> NSMenu {
        let model = Self.model()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(Self.cardItem(
            UsageMenuCardHeaderAndUsageSectionView(
                model: model, layoutModel: model, bottomPadding: 4, width: 320),
            id: "menuCardUsage"))
        menu.addItem(.separator())
        menu.addItem(Self.cardItem(
            UsageMenuCardCreditsSectionView(
                model: model, showBottomDivider: false, topPadding: 6, bottomPadding: 4, width: 320),
            id: "menuCardCredits"))
        menu.addItem(withTitle: "Buy Credits…", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Usage Dashboard", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "q")
        return menu
    }

    private static func cardItem(_ content: some View, id: String) -> NSMenuItem {
        let payload = MenuCardRowPayload(
            content: AnyView(content),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .topTrailing,
            submenuIndicatorTopPadding: 8,
            allowsMenuHighlight: false,
            containsInteractiveControls: false,
            usesGPUSelection: false,
            onClick: nil)
        let row = MenuRowContainerView(payload: payload, refreshMonitor: nil)
        row.applyMeasuredSize(width: 320, height: ceil(row.measuredHeight(width: 320) + 7))
        let item = MenuCardMenuItem()
        item.title = ""
        item.representedObject = id
        item.view = row
        item.isEnabled = true
        return item
    }

    private static func model() -> UsageMenuCardView.Model {
        let dashboard = InlineUsageDashboardModel(
            accessibilityLabel: "Synthetic cost history",
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: "Today", value: "≥ $2.39", emphasis: true),
                .init(title: "Est. current window", value: "≥ $452.34", emphasis: false),
                .init(title: "30d", value: "≥ $3.58", emphasis: false),
                .init(title: "30d tokens", value: "≥ 24B", emphasis: false),
            ],
            points: (0..<30).map { index in
                .init(
                    id: "\(index)",
                    label: "Day \(index + 1)",
                    value: Double((index * 37) % 100),
                    accessibilityValue: "Synthetic day")
            },
            detailLines: [],
            quotaWindows: [],
            barColor: .cyan,
            currencyCode: "USD",
            summaryNote: "Local API-rate estimate · Partial coverage")
        return UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "preview@example.com",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: "Pro 20x",
            metrics: [.init(
                id: "secondary",
                title: "Weekly",
                percent: 68,
                percentStyle: .left,
                resetText: "Resets in 6d 2h",
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true)],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: dashboard,
            creditsText: "62500 left",
            creditsRemaining: 62500,
            creditsShowProgress: false,
            limitResetCredits: .init(text: "2 available", items: [
                .init(expiryText: "Expires in 16d 19h", compactExpiryText: "16d 19h"),
                .init(expiryText: "Expires in 23d 17h", compactExpiryText: "23d 17h"),
            ]),
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .cyan)
    }
}

@MainActor
private final class MenuBackdropProofCapture {
    let menu: NSMenu
    let directory: URL
    let label: String
    private(set) var completed = false
    private(set) var failure: Error?

    init(menu: NSMenu, directory: URL, label: String) {
        self.menu = menu
        self.directory = directory
        self.label = label
    }

    func captureAndClose() {
        defer {
            self.completed = true
            self.menu.cancelTracking()
        }
        do {
            let window = try XCTUnwrap(self.menu.items.lazy.compactMap { $0.view?.window }.first)
            window.displayIfNeeded()
            let displayTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let frame = window.frame.integral
            let region = [frame.minX, displayTop - frame.maxY, frame.width, frame.height]
                .map { String(Int($0)) }.joined(separator: ",")
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = [
                "-x", "-R", region,
                self.directory.appendingPathComponent("\(self.label)-native-menu.png").path,
            ]
            try screenshot.run()
            screenshot.waitUntilExit()
            XCTAssertEqual(screenshot.terminationStatus, 0, "Native menu capture failed.")
            let context = Process()
            context.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            context.arguments = [
                "-x", self.directory.appendingPathComponent("\(self.label)-desktop-context.png").path,
            ]
            try context.run()
            context.waitUntilExit()
            XCTAssertEqual(context.terminationStatus, 0, "Native context capture failed.")
            let receipt: [String: Any] = [
                "appearance": window.effectiveAppearance.name.rawValue,
                "menuFrame": NSStringFromRect(window.frame),
                "rows": self.menu.items.compactMap { item -> [String: Any]? in
                    guard let row = item.view else { return nil }
                    return [
                        "id": item.representedObject as? String ?? "",
                        "opaque": row.isOpaque,
                        "frame": NSStringFromRect(row.frame),
                        "appearance": row.effectiveAppearance.name.rawValue,
                    ]
                },
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: self.directory.appendingPathComponent("\(self.label)-geometry.json"))
        } catch { self.failure = error }
    }
}

@MainActor
private final class MenuBackdropProofBackground: NSView {
    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let colors: [NSColor] = [.systemPink, .systemYellow, .systemTeal, .black, .systemBlue, .white]
        for yIndex in 0..<12 {
            for xIndex in 0..<10 {
                let rect = NSRect(x: CGFloat(xIndex * 100), y: CGFloat(yIndex * 70), width: 100, height: 70)
                colors[(xIndex + yIndex) % colors.count].setFill()
                rect.fill()
                ("BUSY DESKTOP" as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 22), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.gray,
                ])
            }
        }
    }
}
