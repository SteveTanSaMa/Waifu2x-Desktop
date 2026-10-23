import XCTest
import AppKit
import SwiftUI
@testable import Waifu2x

@MainActor
final class OnboardingTests: XCTestCase {
    func testFirstLaunchRemainsEligibleUntilExplicitCompletion() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            XCTAssertFalse(state.isPresented)

            state.presentIfNeeded(arguments: [])
            XCTAssertTrue(state.isPresented)
            XCTAssertEqual(state.step, .addImages)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

            state.advance()
            state.advance()
            XCTAssertEqual(state.step, .compareAndExport)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey),
                         "Reaching the last page must not consume the first-run tutorial")

            let nextLaunch = OnboardingState(defaults: defaults)
            nextLaunch.presentIfNeeded(arguments: [])
            XCTAssertTrue(nextLaunch.isPresented, "An interrupted tutorial must be offered again")

            nextLaunch.complete()
            XCTAssertFalse(nextLaunch.isPresented)
            XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)
        }
    }

    func testCompletedTutorialDoesNotAutomaticallyReappear() throws {
        try withIsolatedDefaults { defaults in
            let firstLaunch = OnboardingState(defaults: defaults)
            firstLaunch.presentIfNeeded(arguments: [])
            firstLaunch.complete()

            firstLaunch.presentIfNeeded(arguments: [])
            XCTAssertFalse(firstLaunch.isPresented)

            let nextLaunch = OnboardingState(defaults: defaults)
            nextLaunch.presentIfNeeded(arguments: [])
            XCTAssertFalse(nextLaunch.isPresented)
        }
    }

    func testManualReopeningResetsToFirstPageAfterCompletion() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.presentIfNeeded(arguments: [])
            state.select(.compareAndExport)
            state.complete()

            state.show()
            XCTAssertTrue(state.isPresented)
            XCTAssertEqual(state.step, .addImages)
            XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)

            state.advance()
            state.show()
            XCTAssertEqual(state.step, .addImages, "Every manual reopening begins with the import page")
            state.complete()
            state.show()
            XCTAssertTrue(state.isPresented, "Completion must not prevent reopening the tutorial from Help")
        }
    }

    func testStepNavigationStaysWithinTutorialBounds() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.show()
            state.back()
            XCTAssertEqual(state.step, .addImages)

            state.advance()
            XCTAssertEqual(state.step, .enhance)
            state.advance()
            XCTAssertEqual(state.step, .compareAndExport)
            state.advance()
            XCTAssertEqual(state.step, .compareAndExport)
            XCTAssertTrue(state.isPresented, "Advancing at the last page must wait for explicit completion")

            state.back()
            XCTAssertEqual(state.step, .enhance)
            state.back()
            state.back()
            XCTAssertEqual(state.step, .addImages)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))
        }
    }

    func testSampleLaunchBypassesTutorialWithoutConsumingFirstRun() throws {
        try withIsolatedDefaults { defaults in
            let sampleLaunch = OnboardingState(defaults: defaults)
            sampleLaunch.presentIfNeeded(arguments: ["--sample"])
            XCTAssertFalse(sampleLaunch.isPresented)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

            sampleLaunch.presentIfNeeded(arguments: [])
            XCTAssertFalse(sampleLaunch.isPresented, "Launch eligibility is checked once per session")

            let normalLaunch = OnboardingState(defaults: defaults)
            normalLaunch.presentIfNeeded(arguments: [])
            XCTAssertTrue(normalLaunch.isPresented)
        }
    }

    func testIsolatedSessionDoesNotAutomaticallyPresentOrPersistCompletion() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.presentIfNeeded(arguments: ["--isolated-session"])
            XCTAssertFalse(state.isPresented)

            state.show()
            state.complete()
            XCTAssertFalse(state.isPresented)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

            let normalLaunch = OnboardingState(defaults: defaults)
            normalLaunch.presentIfNeeded(arguments: [])
            XCTAssertTrue(normalLaunch.isPresented)
        }
    }

    func testForcedTutorialInIsolatedSessionDoesNotPersistCompletion() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.presentIfNeeded(arguments: ["--isolated-session", "--show-onboarding", "--sample"])
            XCTAssertTrue(state.isPresented, "The explicit tutorial flag also overrides the sample-launch bypass")

            state.complete()
            XCTAssertFalse(state.isPresented)
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

            let normalLaunch = OnboardingState(defaults: defaults)
            normalLaunch.presentIfNeeded(arguments: [])
            XCTAssertTrue(normalLaunch.isPresented)
        }
    }

    func testTestingSessionSuppressesAutomaticPresentationAndPreferenceWrites() throws {
        try withIsolatedDefaults { defaults in
            let state = OnboardingState(defaults: defaults)
            state.presentIfNeeded(arguments: [], isTesting: true)
            XCTAssertFalse(state.isPresented)

            state.show()
            state.complete()
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

            let forcedState = OnboardingState(defaults: defaults)
            forcedState.presentIfNeeded(arguments: ["--show-onboarding"], isTesting: true)
            XCTAssertTrue(forcedState.isPresented)
            forcedState.complete()
            XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))
        }
    }

    func testForcedPreviewPreservesExistingCompletionVersion() throws {
        try withIsolatedDefaults { defaults in
            let savedVersion = OnboardingState.currentVersion + 1
            defaults.set(savedVersion, forKey: OnboardingState.completionKey)
            let state = OnboardingState(defaults: defaults)
            state.presentIfNeeded(arguments: ["--isolated-session", "--show-onboarding"])
            XCTAssertTrue(state.isPresented)
            state.complete()
            XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), savedVersion,
                           "A QA preview must preserve an existing completion flag as well as an absent one")
        }
    }

    func testEveryTutorialStepFillsBothWindowSizesAndAppearancesAsStaticPreview() throws {
        try withIsolatedDefaults { defaults in
            let directory = URL(fileURLWithPath: "/tmp/Waifu2x-onboarding-validation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            for size in [CGSize(width: 1280, height: 768), CGSize(width: 1728, height: 1000)] {
                for scheme in [ColorScheme.light, .dark] {
                    for step in OnboardingStep.allCases {
                        let state = OnboardingState(defaults: defaults)
                        state.show()
                        state.select(step)
                        try renderTutorial(state, size: size, colorScheme: scheme, to: directory)
                        XCTAssertTrue(state.isPresented)
                        XCTAssertEqual(state.step, step)
                        XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey),
                                     "Rendering previews must not mark the tutorial as completed")
                    }
                }
            }
        }
    }

    private func renderTutorial(_ state: OnboardingState, size: CGSize, colorScheme: ColorScheme, to directory: URL) throws {
        let root = OnboardingView(onboarding: state, animates: false) { _ in
            XCTFail("Rendering the tutorial must not invoke its finish action")
        }
        .environment(\.colorScheme, colorScheme)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.bounds.size, size)
        try assertTutorialLayout(in: host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        XCTAssertNotEqual(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2),
                          bitmap.colorAt(x: 0, y: 0), "The tutorial must render visible content, not an empty surface")

        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let name = "onboarding-\(Int(size.width))x\(Int(size.height))-\(colorScheme == .light ? "light" : "dark")-\(state.step.rawValue)"
        let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
        try png.write(to: destination)
        let savedImage = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        XCTAssertEqual(savedImage.pixelsWide, bitmap.pixelsWide)
        XCTAssertEqual(savedImage.pixelsHigh, bitmap.pixelsHigh)

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertTutorialLayout(in host: NSView) throws {
        func probe(_ identifier: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { probe(identifier, in: $0) }.first
        }
        func rect(_ identifier: String) throws -> CGRect {
            let view = try XCTUnwrap(probe(identifier, in: host), identifier)
            let frame = view.convert(view.bounds, to: host)
            XCTAssertGreaterThan(frame.width, 0, identifier)
            XCTAssertGreaterThan(frame.height, 0, identifier)
            XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(identifier) must remain inside the window: \(frame)")
            return frame
        }
        let animation = try rect("onboardingAnimationBounds")
        let instructions = try rect("onboardingInstructionsBounds")
        let header = try rect("onboardingHeaderBounds")
        let brand = try rect("onboardingBrandBounds")
        let footer = try rect("onboardingFooterBounds")
        XCTAssertFalse(animation.intersects(instructions), "Animation and instructions must not overlap")
        XCTAssertFalse(animation.intersects(footer), "Animation must not cover navigation")
        XCTAssertFalse(instructions.intersects(footer), "Instructions must not cover navigation")
        XCTAssertFalse(header.intersects(animation), "The demo must not cover the title and skip action")
        XCTAssertFalse(header.intersects(instructions), "Instructions must remain below the title bar")
        XCTAssertLessThan(animation.midX, instructions.midX, "The animation belongs in the left column")
        XCTAssertGreaterThanOrEqual(instructions.minX - animation.maxX, 39.5,
                                    "A readable gap must separate the left animation and right instructions")
        XCTAssertEqual(animation.midY, instructions.midY, accuracy: 0.5,
                       "The two columns must share a vertical center")
        XCTAssertGreaterThanOrEqual(instructions.width, 319.5,
                                    "The instructions need enough width for readable Chinese text")
        XCTAssertLessThanOrEqual(instructions.width, 420.5,
                                 "The instructions should remain a compact reading column")
        XCTAssertGreaterThanOrEqual(brand.minX, 115.5, "Header text must clear the native traffic lights")
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "Waifu2x.OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
