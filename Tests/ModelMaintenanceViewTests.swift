import AppKit
import SwiftUI
import XCTest
@testable import Waifu2x

@MainActor
final class ModelMaintenanceViewTests: XCTestCase {
    private let windowSize = CGSize(width: 720, height: 520)

    func testMissingModelCheckShowsVisibleRepairActionsInEveryLanguageAndAppearance() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        for language in AppLocalization.supportedLanguages {
            preferences.languageCode = language
            for scheme in [ColorScheme.light, .dark] {
                try await renderMissingModel(language: language, scheme: scheme)
            }
        }
    }

    func testNativeRepairButtonCompletesAnOfflinePartialRepair() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        preferences.languageCode = "fr"
        let fixture = try ModelMaintenanceTests.Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let requests = MaintenanceRequests()
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, requests: requests)
        maintenance.recordStartupReady()
        try fixture.removeModel(1)
        let (window, host) = makeWindow(checker: checker, maintenance: maintenance, scheme: .light)
        defer { window.close() }
        let check = try await visibleControl("checkFileIntegrity", in: host, window: window)
        try click(check, in: window)
        try await wait("Clicking Check must report the missing model") { checker.status == .issues && checker.canStart }
        let repair = try await visibleControl("repairModels", in: host, window: window)
        try click(repair, in: window)
        try await wait("Clicking the native repair button must finish the offline repair") {
            maintenance.repairOutcome == .completed && !maintenance.isRepairing
        }
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL])
        XCTAssertEqual(checker.modelVerification, .valid)
        XCTAssertEqual(checker.status, .valid)
        XCTAssertTrue(maintenance.modelsCanBeUsed)
        XCTAssertEqual(maintenance.installedBytes, fixture.catalog.totalModelBytes)
        _ = try await visibleControl("checkFileIntegrity", in: host, window: window)
        XCTAssertTrue(visibleProbes("repairModels", in: host).isEmpty, "A repaired cache has no reinstall button")
    }

    private func renderMissingModel(language: String, scheme: ColorScheme) async throws {
        let fixture = try ModelMaintenanceTests.Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker)
        maintenance.recordStartupReady()
        try fixture.removeModel(1)
        let (window, host) = makeWindow(checker: checker, maintenance: maintenance, scheme: scheme)
        defer { window.close() }
        let check = try await visibleControl("checkFileIntegrity", in: host, window: window)
        XCTAssertTrue(visibleProbes("repairModels", in: host).isEmpty)
        try click(check, in: window)
        try await wait("The missing model must be reflected in Settings") {
            checker.status == .issues && checker.canStart && maintenance.hasModelIssues
        }
        var buttonFrames: [CGRect] = []
        for identifier in ["checkFileIntegrity", "repairModels", "revealModels"] {
            let control = try await visibleControl(identifier, in: host, window: window)
            buttonFrames.append(control.convert(control.bounds, to: host))
        }
        for identifier in ["modelStatus", "modelStorageSize"] {
            _ = try await visibleControl(identifier, in: host, window: window)
        }
        for left in buttonFrames.indices {
            for right in buttonFrames.indices where right > left {
                let intersection = buttonFrames[left].intersection(buttonFrames[right])
                XCTAssertTrue(intersection.isNull || intersection.width < 0.5 || intersection.height < 0.5,
                              "Native action buttons must not overlap in \(language) \(scheme)")
            }
        }
        XCTAssertEqual(host.bounds.size, windowSize)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertEqual(maintenance.diagnosticStatus, .issues)
        if ["fr", "ru", "zh-Hans"].contains(language) {
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "model-repair-issues-\(language)-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func makeWindow(checker: FileIntegrityChecker, maintenance: ModelMaintenance,
                            scheme: ColorScheme) -> (NSWindow, NSHostingView<AnyView>) {
        let navigation = SettingsNavigation()
        navigation.selection = .models
        let updates = AppUpdateChecker(transport: { _ in throw URLError(.notConnectedToInternet) })
        let root = SettingsView(preferences: .shared, navigation: navigation, updates: updates,
                                integrity: checker, modelsAreReady: true, canShowTutorial: false,
                                onShowTutorial: {}, maintenance: maintenance)
            .environment(\.locale, AppPreferences.shared.locale)
            .environment(\.colorScheme, scheme)
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: windowSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func visibleProbes(_ identifier: String, in host: NSView) -> [NSView] {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return descendants(host).filter { view in
            guard view.identifier?.rawValue == identifier, view.window === host.window,
                  !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 20, view.bounds.height > 15 else { return false }
            let frame = view.convert(view.bounds, to: host)
            // A representable mounted in a rejected ViewThatFits candidate or
            // outside a Form clip is not a visible, clickable control.
            return host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                && view.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(view.bounds)
        }
    }

    private func visibleControl(_ identifier: String, in host: NSView, window: NSWindow) async throws -> NSView {
        let deadline = Date().addingTimeInterval(3)
        var previous: CGRect?
        var stableSince = Date()
        while Date() < deadline {
            if window.contentLayoutRect.size != windowSize { window.setContentSize(windowSize) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if window.isVisible, let control = visibleProbes(identifier, in: host).first {
                let frame = control.convert(control.bounds, to: nil)
                if frame == previous, Date().timeIntervalSince(stableSince) > 0.12 { return control }
                if frame != previous { stableSince = Date() }
                previous = frame
            } else {
                previous = nil
                stableSince = Date()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = "\(identifier) must fit completely inside the visible 720 × 520 Settings window"
        XCTFail(message)
        throw NSError(domain: "ModelMaintenanceViewTests.Layout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func click(_ control: NSView, in window: NSWindow) throws {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func wait(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message)
                throw NSError(domain: "ModelMaintenanceViewTests.Timeout", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
