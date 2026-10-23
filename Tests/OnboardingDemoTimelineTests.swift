import XCTest
import AppKit
import SwiftUI
@testable import Waifu2x

@MainActor
final class OnboardingDemoTimelineTests: XCTestCase {
    func testImportShowsImageOnlyAfterTheDragReachesTheCanvas() {
        let dragging = authoredFrame(.addImages, 3.2)
        XCTAssertGreaterThan(dragging.draggedImageOpacity, 0)
        XCTAssertEqual(dragging.imageOpacity, 0)
        XCTAssertTrue(dragging.targets.contains(.drop))

        let dropping = authoredFrame(.addImages, 3.85)
        XCTAssertTrue(OnboardingDemoTarget.drop.rect.contains(dropping.cursor))
        XCTAssertGreaterThan(dropping.click, 0)

        let imported = authoredFrame(.addImages, 6.6)
        XCTAssertEqual(imported.imageOpacity, 1)
        XCTAssertEqual(imported.draggedImageOpacity, 0)
        XCTAssertTrue(imported.targets.contains(.queue))
    }

    func testParametersAreSelectedBeforeEnhancementAndCompletionEnablesComparison() {
        let scale = authoredFrame(.enhance, 3.1)
        XCTAssertTrue(scale.scaleIsSelected)
        XCTAssertFalse(scale.noiseIsSelected)
        XCTAssertEqual(scale.enhancementProgress, 0)
        XCTAssertEqual(scale.caption, L("在右侧选择恰当的放大倍率"))
        XCTAssertFalse(scale.caption.contains("2×"), "Guidance must allow choosing an appropriate scale")

        let noise = authoredFrame(.enhance, 5.3)
        XCTAssertTrue(noise.scaleIsSelected)
        XCTAssertTrue(noise.noiseIsSelected)
        XCTAssertEqual(noise.enhancementProgress, 0, "Changing settings must not start processing")

        let processing = authoredFrame(.enhance, 7.9)
        XCTAssertGreaterThan(processing.enhancementProgress, 0)
        XCTAssertLessThan(processing.enhancementProgress, 1)
        XCTAssertFalse(processing.showsComparison)
        XCTAssertEqual(processing.exportSheetOpacity, 0)
        XCTAssertFalse(processing.exported)

        XCTAssertEqual(authoredFrame(.enhance, 11).enhancementProgress, 1)
        for step in OnboardingStep.allCases {
            // Duration and elapsed are real seconds, so do not apply the authored-time conversion here.
            for elapsed in stride(from: 0.0, to: OnboardingDemoTimeline.duration(for: step), by: 0.05) {
                let value = frame(step, elapsed)
                if value.enhancementProgress > 0 {
                    XCTAssertTrue(value.scaleIsSelected)
                    XCTAssertTrue(value.noiseIsSelected)
                }
                if value.showsComparison || value.exportSheetOpacity > 0 || value.exported {
                    XCTAssertEqual(value.enhancementProgress, 1,
                                   "Comparison and export must wait for a finished result")
                }
            }
        }
    }

    func testComparisonAppearsAfterClickAndDemonstratesDraggingBothDirections() {
        XCTAssertFalse(authoredFrame(.compareAndExport, 2.3).showsComparison)
        let clicked = authoredFrame(.compareAndExport, 2.7)
        XCTAssertTrue(clicked.showsComparison)
        XCTAssertGreaterThan(clicked.click, 0)
        XCTAssertEqual(clicked.split, 0.5)

        let left = authoredFrame(.compareAndExport, 5.9)
        let right = authoredFrame(.compareAndExport, 7.6)
        XCTAssertTrue(left.showsComparison)
        XCTAssertTrue(right.showsComparison)
        XCTAssertLessThan(left.split, clicked.split)
        XCTAssertGreaterThan(right.split, clicked.split)
        XCTAssertEqual(authoredFrame(.compareAndExport, 8.3).split, 0.5, accuracy: 0.000001)
    }

    func testExportShowsSavePanelAndRequiresStorageConfirmationBeforeSuccess() {
        let exportClick = authoredFrame(.compareAndExport, 10.7)
        XCTAssertGreaterThan(exportClick.click, 0)
        XCTAssertTrue(exportClick.targets.contains(.export))
        XCTAssertEqual(exportClick.exportSheetOpacity, 0)
        XCTAssertFalse(exportClick.exported)

        let savePanel = authoredFrame(.compareAndExport, 12.9)
        XCTAssertEqual(savePanel.exportSheetOpacity, 1)
        XCTAssertTrue(savePanel.targets.contains(.save))
        XCTAssertFalse(savePanel.exported)

        let confirming = authoredFrame(.compareAndExport, 13.4)
        XCTAssertTrue(OnboardingDemoTarget.save.rect.contains(confirming.cursor))
        XCTAssertGreaterThan(confirming.click, 0)
        XCTAssertGreaterThan(confirming.exportSheetOpacity, 0)
        XCTAssertFalse(confirming.exported)

        let saved = authoredFrame(.compareAndExport, 15)
        XCTAssertTrue(saved.exported)
        XCTAssertEqual(saved.exportSheetOpacity, 0)
    }

    func testPlaybackRateLengthensEachPageOnTheRealClock() {
        XCTAssertEqual(OnboardingDemoTimeline.playbackRate, 0.65, accuracy: 0.000001)
        let scripts: [(OnboardingStep, TimeInterval)] = [(.addImages, 11), (.enhance, 13.5), (.compareAndExport, 17)]
        for (step, authoredDuration) in scripts {
            let duration = OnboardingDemoTimeline.duration(for: step)
            XCTAssertEqual(duration, authoredDuration / 0.65, accuracy: 0.000001)
            XCTAssertGreaterThan(duration, authoredDuration)
        }
    }

    func testKeyActionsWaitForTheirSlowerWallClockTimes() {
        let transitions: [(OnboardingStep, TimeInterval, (OnboardingDemoFrame) -> Bool)] = [
            (.addImages, 3.8, { $0.imageOpacity > 0 }),
            (.enhance, 2.8, { $0.scaleIsSelected }),
            (.enhance, 5, { $0.noiseIsSelected }),
            (.enhance, 7.85, { $0.enhancementProgress > 0 }),
            (.enhance, 10.3, { $0.enhancementProgress == 1 }),
            (.compareAndExport, 2.5, { $0.showsComparison }),
            (.compareAndExport, 10.8, { $0.exportSheetOpacity > 0 }),
            (.compareAndExport, 14.1, { $0.exported })
        ]
        for (step, authoredTime, hasOccurred) in transitions {
            let elapsed = authoredTime / OnboardingDemoTimeline.playbackRate
            let context = "\(step): authored \(authoredTime)s, real \(elapsed)s"
            XCTAssertGreaterThan(elapsed, authoredTime, context)
            // Supply real elapsed directly to catch applying the rate zero times or twice.
            XCTAssertFalse(hasOccurred(OnboardingDemoTimeline.frame(step: step, elapsed: elapsed - 0.01)), context)
            XCTAssertTrue(hasOccurred(OnboardingDemoTimeline.frame(step: step, elapsed: elapsed + 0.01)), context)
        }
    }

    func testTimelineSamplesHaveFiniteCoordinatesAndLegalVisualValues() {
        let elapsedValues = [-1_000_000.0, -1, 0, 0.001, 1_000_000_000]
            + Array(stride(from: 0.0, through: 10_000.0, by: 17.37))
        let workspaceBounds = CGRect(origin: .zero, size: OnboardingDemoLayout.size)
        for step in OnboardingStep.allCases {
            XCTAssertGreaterThan(OnboardingDemoTimeline.duration(for: step), 0)
            for elapsed in elapsedValues {
                let value = frame(step, elapsed)
                XCTAssertTrue(value.camera.center.x.isFinite)
                XCTAssertTrue(value.camera.center.y.isFinite)
                XCTAssertTrue(workspaceBounds.contains(value.camera.center))
                XCTAssertTrue(value.camera.zoom.isFinite)
                XCTAssertGreaterThanOrEqual(value.camera.zoom, 1)
                XCTAssertLessThanOrEqual(value.camera.zoom, 4)
                // A dragged image intentionally enters from outside the app window.
                XCTAssertTrue(value.cursor.x.isFinite)
                XCTAssertTrue(value.cursor.y.isFinite)
                for amount in [value.opacity, value.cursorOpacity, value.click, value.imageOpacity,
                               value.draggedImageOpacity, value.enhancementProgress, value.exportSheetOpacity] {
                    XCTAssertTrue(amount.isFinite)
                    XCTAssertGreaterThanOrEqual(amount, 0)
                    XCTAssertLessThanOrEqual(amount, 1)
                }
                XCTAssertTrue(value.split.isFinite)
                XCTAssertGreaterThanOrEqual(value.split, 0.02)
                XCTAssertLessThanOrEqual(value.split, 0.98)
                XCTAssertFalse(value.caption.isEmpty)
            }
        }
    }

    func testTimelineRepeatsTheSameActionsAndCameraEachCycle() {
        for step in OnboardingStep.allCases {
            let duration = OnboardingDemoTimeline.duration(for: step)
            for fraction in [0.0, 0.07, 0.26, 0.51, 0.79, 0.96] {
                let elapsed = duration * fraction
                let expected = frame(step, elapsed)
                for cycle in [1.0, 5, 100, 10_000] {
                    assertEqual(frame(step, elapsed + duration * cycle), expected)
                }
            }
            assertEqual(frame(step, -100), frame(step, 0))
        }
    }

    func testReducedMotionStillFramesShowOrderedTargetsWithoutTemporaryOverlays() {
        let expectedTargets: [[OnboardingDemoTarget]] = [[.drop, .queue], [.scale, .noise, .enhance], [.compare, .split, .export]]
        for (index, step) in OnboardingStep.allCases.enumerated() {
            let value = OnboardingDemoTimeline.stillFrame(step: step)
            XCTAssertEqual(value.targets, expectedTargets[index])
            XCTAssertEqual(value.imageOpacity, 1)
            XCTAssertEqual(value.opacity, 1)
            XCTAssertEqual(value.cursorOpacity, 0)
            XCTAssertEqual(value.click, 0)
            XCTAssertEqual(value.draggedImageOpacity, 0)
            XCTAssertEqual(value.exportSheetOpacity, 0)
            XCTAssertFalse(value.exported)
            XCTAssertFalse(value.caption.isEmpty)
        }
        let enhance = OnboardingDemoTimeline.stillFrame(step: .enhance)
        XCTAssertTrue(enhance.scaleIsSelected)
        XCTAssertTrue(enhance.noiseIsSelected)
        let compare = OnboardingDemoTimeline.stillFrame(step: .compareAndExport)
        XCTAssertEqual(compare.enhancementProgress, 1)
        XCTAssertTrue(compare.showsComparison)
    }

    func testKeyClicksHitTheirControlsAndCameraKeepsTheWholeControlVisible() {
        let actions: [(OnboardingStep, Double, OnboardingDemoTarget)] = [
            (.enhance, 2.8, .scale), (.enhance, 5, .noise), (.enhance, 7.7, .enhance),
            (.compareAndExport, 2.5, .compare), (.compareAndExport, 10.6, .export), (.compareAndExport, 13.4, .save)
        ]
        let stages = [CGSize(width: 896, height: 352), CGSize(width: 786, height: 524),
                      CGSize(width: 956, height: 956 / 1.5)]
        for stage in stages {
            let viewport = CGSize(width: stage.width, height: stage.height - 40 - 48)
            let fit = min((viewport.width - 36) / OnboardingDemoLayout.size.width,
                          viewport.height / OnboardingDemoLayout.size.height)
            for (step, authoredTime, target) in actions {
                let value = authoredFrame(step, authoredTime)
                let context = "\(step) at authored \(authoredTime): \(target), stage \(stage)"
                XCTAssertTrue(target.rect.contains(value.cursor), context)
                XCTAssertGreaterThan(value.click, 0, context)
                XCTAssertTrue(value.targets.contains(target), context)
                let scale = fit * value.camera.zoom
                func project(_ rect: CGRect) -> CGRect {
                    CGRect(x: viewport.width / 2 + (rect.minX - value.camera.center.x) * scale,
                           y: viewport.height / 2 + (rect.minY - value.camera.center.y) * scale,
                           width: rect.width * scale, height: rect.height * scale)
                }
                let projected = project(target.rect)
                XCTAssertGreaterThanOrEqual(projected.minX, 0, context)
                XCTAssertGreaterThanOrEqual(projected.minY, 0, context)
                XCTAssertLessThanOrEqual(projected.maxX, viewport.width, context)
                XCTAssertLessThanOrEqual(projected.maxY, viewport.height, context)
                if target == .save {
                    XCTAssertGreaterThan(value.exportSheetOpacity, 0, context)
                    let panel = project(OnboardingDemoLayout.savePanelRect)
                    let safeViewport = CGRect(origin: .zero, size: viewport).insetBy(dx: 8, dy: 8)
                    XCTAssertTrue(safeViewport.contains(panel),
                                  "The whole save panel must remain visible with breathing room: \(panel), \(context)")
                }
            }
        }
    }

    func testKeyCameraFramesRenderForVisualInspection() throws {
        let directory = URL(fileURLWithPath: "/tmp/Waifu2x-onboarding-camera-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let moments: [(OnboardingStep, [Double])] = [
            (.addImages, [3.2, 6.6]), (.enhance, [3.1, 5.3, 7.9, 11]),
            (.compareAndExport, [2.7, 6.5, 10.7, 12.9, 15])
        ]
        for (step, times) in moments {
            for time in times {
                try renderCamera(step: step, time: time, scheme: .light, to: directory)
            }
            try renderCamera(step: step, time: try XCTUnwrap(times.last), scheme: .dark, to: directory)
        }
    }

    private func frame(_ step: OnboardingStep, _ elapsed: Double) -> OnboardingDemoFrame {
        OnboardingDemoTimeline.frame(step: step, elapsed: elapsed)
    }

    private func authoredFrame(_ step: OnboardingStep, _ authoredTime: TimeInterval) -> OnboardingDemoFrame {
        frame(step, realElapsed(forAuthoredTime: authoredTime))
    }

    private func realElapsed(forAuthoredTime authoredTime: TimeInterval) -> TimeInterval {
        // Capture just after a scripted event so floating-point round trips cannot precede a click.
        (authoredTime + 0.000000001) / OnboardingDemoTimeline.playbackRate
    }

    private func assertEqual(_ actual: OnboardingDemoFrame, _ expected: OnboardingDemoFrame,
                             file: StaticString = #filePath, line: UInt = #line) {
        let coordinates = [(actual.camera.center.x, expected.camera.center.x), (actual.camera.center.y, expected.camera.center.y),
                           (actual.camera.zoom, expected.camera.zoom), (actual.cursor.x, expected.cursor.x),
                           (actual.cursor.y, expected.cursor.y), (actual.split, expected.split)]
        for (a, b) in coordinates { XCTAssertEqual(a, b, accuracy: 0.000001, file: file, line: line) }
        let amounts = [(actual.cursorOpacity, expected.cursorOpacity), (actual.click, expected.click),
                       (actual.imageOpacity, expected.imageOpacity), (actual.draggedImageOpacity, expected.draggedImageOpacity),
                       (actual.enhancementProgress, expected.enhancementProgress), (actual.exportSheetOpacity, expected.exportSheetOpacity),
                       (actual.opacity, expected.opacity)]
        for (a, b) in amounts { XCTAssertEqual(a, b, accuracy: 0.000001, file: file, line: line) }
        XCTAssertEqual(actual.scaleIsSelected, expected.scaleIsSelected, file: file, line: line)
        XCTAssertEqual(actual.noiseIsSelected, expected.noiseIsSelected, file: file, line: line)
        XCTAssertEqual(actual.showsComparison, expected.showsComparison, file: file, line: line)
        XCTAssertEqual(actual.exported, expected.exported, file: file, line: line)
        XCTAssertEqual(actual.targets, expected.targets, file: file, line: line)
        XCTAssertEqual(actual.caption, expected.caption, file: file, line: line)
    }

    private func renderCamera(step: OnboardingStep, time: Double, scheme: ColorScheme, to directory: URL) throws {
        let size = CGSize(width: 896, height: 352)
        let root = OnboardingIllustration(step: step, animates: false, previewTime: realElapsed(forAuthoredTime: time))
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let moment = String(format: "%.1f", time).replacingOccurrences(of: ".", with: "-")
        let name = "camera-\(scheme == .light ? "light" : "dark")-\(step.rawValue)-\(moment)"
        let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
        try png.write(to: destination)
        let saved = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        XCTAssertGreaterThan(saved.pixelsWide, 0)
        XCTAssertGreaterThan(saved.pixelsHigh, 0)
        XCTAssertEqual(saved.pixelsWide, bitmap.pixelsWide)
        XCTAssertEqual(saved.pixelsHigh, bitmap.pixelsHigh)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
