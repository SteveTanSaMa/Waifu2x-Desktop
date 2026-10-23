import XCTest
import AppKit
import SwiftUI
@testable import Waifu2x

@MainActor
final class WorkspaceRootTests: XCTestCase {
    func testStartupBlocksWorkspaceInputAndEscapeCannotSkipModelPreparation() async throws {
        let suiteName = "Waifu2x.StartupRootTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let panels = workspace.activePanels
        let onboarding = OnboardingState(defaults: defaults)
        let startup = AppStartupState()
        let host = NSHostingView(rootView: WorkspaceRootView(workspace: workspace, onboarding: onboarding,
                                                           animates: false, startup: startup))
        let window = makeWindow(hosting: host)
        defer { window.close() }
        try await waitFor("The startup Escape monitor must be attached") {
            self.views(of: WindowProbe.self, in: host).first?.onEscape != nil
        }
        XCTAssertTrue(views(of: CanvasView.self, in: host).isEmpty)
        XCTAssertTrue(views(of: CanvasControlsHostView.self, in: host).isEmpty)
        let monitor = try XCTUnwrap(views(of: WindowProbe.self, in: host).first)
        XCTAssertTrue(monitor.onEscape?() ?? false)
        XCTAssertEqual(startup.phase, .splash)
        XCTAssertFalse(onboarding.isPresented)
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), 0)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertNil(window.attachedSheet)
    }

    func testTutorialUsesMainWindowAndPreservesWorkspaceWhenCompletedAndReopened() async throws {
        let suiteName = "Waifu2x.WorkspaceRootTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.openSample()
        try await waitFor("The sample must finish importing") { !workspace.isLoading }
        XCTAssertNil(workspace.errorMessage)
        let item = try XCTUnwrap(workspace.selectedImage)
        workspace.options = ProcessingOptions(scale: 4, noise: 1)
        let options = workspace.options
        item.result = ProcessingResult(asset: item.input, options: options, duration: 0.1)
        workspace.zoom = 1.75
        workspace.preview = .compare
        workspace.split = 0.37
        let inputID = item.input.id
        let resultID = try XCTUnwrap(item.result?.asset.id)
        let panels = workspace.activePanels

        let onboarding = OnboardingState(defaults: defaults)
        onboarding.presentIfNeeded(arguments: [])
        let host = NSHostingView(rootView: WorkspaceRootView(workspace: workspace, onboarding: onboarding, animates: false))
        let window = makeWindow(hosting: host)
        defer { window.close() }
        try await waitFor("The full-window tutorial must be mounted") {
            self.probe("onboardingAnimationBounds", in: host) != nil
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(views(of: CanvasView.self, in: host).isEmpty,
                      "The native canvas must be unmounted while the tutorial accepts input")
        XCTAssertTrue(views(of: CanvasControlsHostView.self, in: host).isEmpty)
        XCTAssertEqual(views(of: WindowProbe.self, in: host).count, 1)
        let nativeProbe = try XCTUnwrap(views(of: WindowProbe.self, in: host).first)
        let brand = try XCTUnwrap(probe("onboardingBrandBounds", in: host))
        let brandRect = brand.convert(brand.bounds, to: host)
        XCTAssertGreaterThanOrEqual(brandRect.minX, 115.5)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertFalse(brandRect.intersects(button.convert(button.bounds, to: host)),
                           "The full-window tutorial title must not cover native window controls")
        }
        let windowIDs = Set(NSApp.windows.map { ObjectIdentifier($0) })

        onboarding.complete()
        try await waitFor("Completing the tutorial must restore the native canvas") {
            !self.views(of: CanvasView.self, in: host).isEmpty
        }
        XCTAssertNil(probe("onboardingAnimationBounds", in: host))
        XCTAssertTrue(host.window === window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(workspace.selectedImage === item)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertEqual(workspace.input?.id, inputID)
        XCTAssertEqual(workspace.result?.asset.id, resultID)
        XCTAssertEqual(workspace.options, options)
        XCTAssertEqual(workspace.zoom, 1.75)
        XCTAssertEqual(workspace.preview, .compare)
        XCTAssertEqual(workspace.split, 0.37)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.input.url.path))
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)
        XCTAssertTrue(views(of: WindowProbe.self, in: host).first === nativeProbe)

        onboarding.select(.compareAndExport)
        onboarding.show()
        try await waitFor("Help must reopen the tutorial in the same window") {
            self.probe("onboardingAnimationBounds", in: host) != nil && self.views(of: CanvasView.self, in: host).isEmpty
        }
        XCTAssertEqual(onboarding.step, .addImages)
        XCTAssertTrue(host.window === window)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(Set(NSApp.windows.map { ObjectIdentifier($0) }).subtracting(windowIDs).isEmpty,
                      "Reopening the tutorial must not create another window")
        XCTAssertTrue(views(of: WindowProbe.self, in: host).first === nativeProbe)
    }

    func testWindowEscapeClosesTutorialWithoutChangingWorkspacePanels() async throws {
        let suiteName = "Waifu2x.WorkspaceRootTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.openSample()
        try await waitFor("The sample must finish importing") { !workspace.isLoading }
        let selectedID = workspace.selectedID
        workspace.activePanels = [.images, .options]
        let initialPanels = workspace.activePanels
        let onboarding = OnboardingState(defaults: defaults)
        onboarding.presentIfNeeded(arguments: [])
        let host = NSHostingView(rootView: WorkspaceRootView(workspace: workspace, onboarding: onboarding, animates: false))
        let window = makeWindow(hosting: host)
        defer { window.close() }
        try await waitFor("The root Escape monitor must be attached") {
            self.views(of: WindowProbe.self, in: host).first?.onEscape != nil
        }
        let monitor = try XCTUnwrap(views(of: WindowProbe.self, in: host).first)
        XCTAssertTrue(monitor.onEscape?() ?? false)
        XCTAssertFalse(onboarding.isPresented)
        XCTAssertEqual(workspace.activePanels, initialPanels,
                       "Escape must finish the tutorial before reaching the workspace")
        XCTAssertEqual(workspace.selectedID, selectedID)
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)
        try await waitFor("Escape must return to the workspace") {
            !self.views(of: CanvasView.self, in: host).isEmpty
        }
        XCTAssertEqual(views(of: WindowProbe.self, in: host).count, 1)

        onboarding.show()
        try await waitFor("The reopened tutorial must replace the native canvas") {
            self.probe("onboardingAnimationBounds", in: host) != nil && self.views(of: CanvasView.self, in: host).isEmpty
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(monitor.onEscape?() ?? false)
        XCTAssertFalse(onboarding.isPresented)
        XCTAssertEqual(workspace.activePanels, initialPanels)

        XCTAssertTrue(monitor.onEscape?() ?? false, "With no tutorial, Escape must reach workspace panels")
        XCTAssertTrue(workspace.activePanels.isEmpty)
        XCTAssertFalse(monitor.onEscape?() ?? false, "An idle workspace with no panels has nothing to dismiss")
    }

    private func makeWindow(hosting host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: CanvasPanelLayout.minimumWindowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message)
                throw NSError(domain: "WorkspaceRootTests.Timeout", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func probe(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.probe(identifier, in: $0) }.first
    }

    private func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(of: type, in: $0) }
    }
}
