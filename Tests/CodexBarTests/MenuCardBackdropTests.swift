import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct MenuCardBackdropTests {
    @Test
    func `data row backing covers busy backgrounds and follows appearance`() throws {
        let payload = MenuCardRowPayload(
            content: AnyView(Color.clear),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .center,
            submenuIndicatorTopPadding: 0,
            allowsMenuHighlight: false,
            containsInteractiveControls: false,
            usesGPUSelection: false,
            onClick: nil)
        let row = MenuRowContainerView(payload: payload, refreshMonitor: nil)
        row.applyMeasuredSize(width: 100, height: 60)
        #expect(!row.isOpaque)

        var brightness: [CGFloat] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: name)
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 100,
                pixelsHigh: 60,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.magenta.setFill()
            row.bounds.fill()
            row.draw(row.bounds)
            NSGraphicsContext.restoreGraphicsState()

            for point in [(7, 30), (50, 3), (92, 30), (50, 56), (50, 30)] {
                let color = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                #expect(color.alphaComponent == 1)
                #expect(abs(color.redComponent - color.greenComponent) < 0.02)
                #expect(abs(color.greenComponent - color.blueComponent) < 0.02)
            }
            for point in [(0, 0), (99, 0), (0, 59), (99, 59)] {
                let color = try #require(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                #expect(color.redComponent == 1)
                #expect(color.greenComponent == 0)
                #expect(color.blueComponent == 1)
            }
            try brightness.append(#require(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.deviceRGB)).redComponent)
        }
        #expect(brightness[0] - brightness[1] > 0.5)
    }
}
