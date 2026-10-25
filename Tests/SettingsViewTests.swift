import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Waifu2x

@MainActor
final class SettingsViewTests: XCTestCase {
    private let settingsSize = CGSize(width: 720, height: 520)

    func testEveryPaneFitsTheCompactSettingsWindowInAllLanguagesAndAppearances() async throws {
        let preferences = AppPreferences.shared
        let previous = (preferences.languageCode, preferences.appearance)
        defer { preferences.languageCode = previous.0; preferences.appearance = previous.1 }
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        for language in AppLocalization.supportedLanguages {
            preferences.languageCode = language
            for scheme in [ColorScheme.light, .dark] {
                try await renderAllPanes(preferences: preferences, services: services,
                                         language: language, scheme: scheme)
            }
        }
        XCTAssertEqual(services.updates.status, .idle, "Rendering must not start an update request")
        XCTAssertEqual(services.integrity.status, .idle, "Rendering must not start a file scan")
    }

    func testSidebarNavigationChangesPanesInTheSameNativeWindow() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        preferences.languageCode = "en"
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let navigation = SettingsNavigation()
        let (window, host) = makeWindow(preferences: preferences, navigation: navigation, services: services)
        defer { window.close() }
        try await waitFor("The native settings sidebar must be mounted") {
            self.views(of: NSTableView.self, in: host).contains { $0.numberOfRows == SettingsSection.allCases.count }
        }
        let sidebar = try XCTUnwrap(views(of: NSTableView.self, in: host).first { $0.numberOfRows == 4 })
        for (index, section) in SettingsSection.allCases.enumerated() {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await waitFor("Selecting \(section.rawValue) must update the detail pane") {
                navigation.selection == section && self.requiredIdentifiers(for: section).allSatisfy {
                    self.probe($0, in: host) != nil
                }
            }
            XCTAssertTrue(host.window === window)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(sidebar.selectedRow, index)
            for other in SettingsSection.allCases where other != section {
                for identifier in requiredIdentifiers(for: other) {
                    XCTAssertNil(probe(identifier, in: host), "Inactive settings controls must leave the view hierarchy")
                }
            }
        }
    }

    func testNativeSettingsMenuTogglesAndRecentersACompactIndependentWindow() async throws {
        let mainWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "Waifu2x" && $0.isVisible })
        let originalMainFrame = mainWindow.frame
        let screen = try XCTUnwrap(mainWindow.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        var openedWindows: [NSWindow] = []
        defer {
            openedWindows.filter(\.isVisible).forEach { $0.close() }
            mainWindow.setFrame(originalMainFrame, display: true)
        }
        // Keep the expected settings rectangle inside the screen so the test
        // measures centering rather than the display-edge clamping fallback.
        mainWindow.setFrameOrigin(CGPoint(x: visible.midX - mainWindow.frame.width / 2,
                                           y: visible.midY - mainWindow.frame.height / 2))
        let mainFrame = mainWindow.frame

        try performSettingsMenuAction()
        try await waitFor("The Settings shortcut must open centered on the main window") {
            guard let settings = self.nativeSettingsWindow() else { return false }
            return self.isCentered(settings, over: mainWindow)
        }
        let settingsWindow = try XCTUnwrap(nativeSettingsWindow())
        openedWindows.append(settingsWindow)
        let settingsContent = try XCTUnwrap(settingsWindow.contentView)
        let bounds = try XCTUnwrap(probe("settingsBounds", in: settingsContent))
        XCTAssertEqual(bounds.bounds.size, settingsSize)
        XCTAssertFalse(settingsWindow === mainWindow)
        XCTAssertNil(mainWindow.attachedSheet)
        XCTAssertNil(settingsWindow.attachedSheet)
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(mainWindow.frame, mainFrame)

        // A remembered position from a manual drag must not survive the next
        // presentation. The frame itself, not a stored navigation flag, is the
        // observable result of the placement policy.
        let previousOrigin = CGPoint(x: visible.minX + 8, y: visible.minY + 8)
        settingsWindow.setFrameOrigin(previousOrigin)
        try performSettingsMenuAction()
        try await waitFor("The same Settings shortcut must close an open settings window") {
            !settingsWindow.isVisible && self.nativeSettingsWindow() == nil
        }
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(mainWindow.frame, mainFrame)

        let dx = min(70, max(0, (visible.width - settingsWindow.frame.width) / 4))
        let dy = min(40, max(0, (visible.height - settingsWindow.frame.height) / 4))
        mainWindow.setFrameOrigin(CGPoint(x: mainFrame.minX + dx, y: mainFrame.minY - dy))
        let movedMainFrame = mainWindow.frame
        try performSettingsMenuAction()
        try await waitFor("Reopening Settings must follow the moved main window instead of its old dragged position") {
            guard let settings = self.nativeSettingsWindow() else { return false }
            return self.isCentered(settings, over: mainWindow)
        }
        let movedSettings = try XCTUnwrap(nativeSettingsWindow())
        openedWindows.append(movedSettings)
        let movedContent = try XCTUnwrap(movedSettings.contentView)
        let movedBounds = try XCTUnwrap(probe("settingsBounds", in: movedContent))
        XCTAssertEqual(movedBounds.bounds.size, settingsSize)
        let visibleSettings = NSApp.windows.filter { window in
            window.isVisible && window.contentView.map { self.probe("settingsBounds", in: $0) != nil } == true
        }
        XCTAssertEqual(visibleSettings.count, 1)
        try XCTUnwrap(movedSettings.standardWindowButton(.closeButton)).performClick(nil)
        try await waitFor("The native close button must close only Settings") { !movedSettings.isVisible }
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(mainWindow.frame, movedMainFrame)

        mainWindow.setFrameOrigin(CGPoint(x: mainFrame.minX - dx, y: mainFrame.minY + dy))
        let thirdMainFrame = mainWindow.frame
        try performSettingsMenuAction()
        try await waitFor("Settings must recenter after a native close as well") {
            guard let settings = self.nativeSettingsWindow() else { return false }
            return self.isCentered(settings, over: mainWindow)
        }
        let reopened = try XCTUnwrap(nativeSettingsWindow())
        openedWindows.append(reopened)
        reopened.makeKeyAndOrderFront(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: reopened.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        reopened.sendEvent(escape)
        try await waitFor("Escape must dismiss the native Settings scene") { !reopened.isVisible }
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(mainWindow.frame, thirdMainFrame)
    }

    func testTutorialButtonReopensTutorialWithoutChangingWorkspace() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        preferences.languageCode = "en"
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        services.defaults.set(OnboardingState.currentVersion, forKey: OnboardingState.completionKey)
        let onboarding = OnboardingState(defaults: services.defaults)
        let workspace = Workspace(persistOptions: false)
        workspace.openSample()
        try await waitFor("The existing workspace image must finish importing") { !workspace.isLoading }
        let image = try XCTUnwrap(workspace.selectedImage)
        workspace.options = ProcessingOptions(scale: 4, noise: 1)
        image.result = ProcessingResult(asset: image.input, options: workspace.options, duration: 0.1)
        workspace.zoom = 1.75
        workspace.preview = .compare
        workspace.split = 0.37
        workspace.activePanels = [.images, .options]
        let options = workspace.options
        let panels = workspace.activePanels
        let resultID = image.result?.asset.id
        var presentations = 0
        let (window, host) = makeWindow(preferences: preferences, navigation: SettingsNavigation(), services: services) {
            presentations += 1
            onboarding.show()
        }
        defer { window.close() }
        let button = try await settledControl("settingsTutorial", in: host, window: window)
        try click(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), in: window)
        try await waitFor("The settings action must deliver its tutorial callback") { presentations == 1 }
        XCTAssertTrue(onboarding.isPresented)
        XCTAssertEqual(onboarding.step, .addImages)
        XCTAssertEqual(services.defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)
        XCTAssertTrue(workspace.selectedImage === image)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertEqual(workspace.result?.asset.id, resultID)
        XCTAssertEqual(workspace.options, options)
        XCTAssertEqual(workspace.zoom, 1.75)
        XCTAssertEqual(workspace.preview, .compare)
        XCTAssertEqual(workspace.split, 0.37)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.input.url.path))
        XCTAssertTrue(host.window === window)
    }

    func testSettingsClosesOnItsOwnFocusLossWithoutClosingOtherWindows() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let (settings, host) = makeFocusWindow(services: services)
        defer { settings.close() }
        let other = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 320, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        defer { other.close() }
        try await waitFor("The settings focus observer must be mounted") {
            self.views(of: SettingsWindowFocusView.self, in: host).first?.window === settings
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(settings.isVisible, "Mounting a window before it becomes key must not dismiss it")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(settings.isVisible, "Another window's focus changes must not close Settings")

        settings.simulatesKeyWindow = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        // The deferred close must re-check focus, so a short handoff back to
        // the same window cannot dismiss it while the user continues editing.
        settings.simulatesKeyWindow = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(settings.isVisible)

        let child = SettingsFocusTestWindow(contentRect: CGRect(x: 60, y: 60, width: 180, height: 120),
                                             styleMask: [.titled], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.simulatesKeyWindow = true
        settings.addChildWindow(child, ordered: .above)
        defer { child.close() }
        settings.simulatesKeyWindow = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(settings.isVisible, "A settings-owned child window must not count as leaving Settings")
        settings.removeChildWindow(child)
        child.close()

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        try await waitFor("Losing Settings focus must close only its own window") { !settings.isVisible }
        XCTAssertTrue(other.isVisible)
    }

    func testAppDeactivationClosesSettingsEvenBeforeTheKeyFlagUpdates() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let (settings, host) = makeFocusWindow(services: services)
        defer { settings.close() }
        try await waitFor("The settings focus observer must be mounted") {
            self.views(of: SettingsWindowFocusView.self, in: host).first?.window === settings
        }
        settings.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await waitFor("Switching away from the app must dismiss Settings") { !settings.isVisible }
    }

    func testNotificationPermissionTemporarilyKeepsSettingsOpen() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let navigation = SettingsNavigation()
        var requestingPermission = true
        navigation.preventsFocusDismissal = { requestingPermission }
        let (settings, host) = makeFocusWindow(services: services, navigation: navigation)
        defer { settings.close() }
        try await waitFor("The settings focus observer must be mounted") {
            self.views(of: SettingsWindowFocusView.self, in: host).first?.window === settings
        }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(settings.isVisible, "The system permission prompt must preserve its originating Settings window")
        requestingPermission = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await waitFor("Normal focus dismissal must resume after permission finishes") { !settings.isVisible }
    }

    func testSleepPreferenceControlUpdatesTheSharedWorkflow() async throws {
        let preferences = AppPreferences(defaults: nil)
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let (window, host) = makeWindow(preferences: preferences, navigation: SettingsNavigation(), services: services)
        defer { window.close() }
        XCTAssertTrue(preferences.preventsSleepWhileProcessing)
        let toggle = try await settledControl("settingsPreventsSleep", in: host, window: window)
        try click(at: toggle.convert(NSPoint(x: toggle.bounds.maxX - 12, y: toggle.bounds.midY), to: nil), in: window)
        try await waitFor("The Settings switch must update the shared workflow preference") {
            !preferences.preventsSleepWhileProcessing
        }
        XCTAssertFalse(preferences.notifiesOnCompletion)
    }

    func testUnavailableTutorialAndModelCheckStayDisabled() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let navigation = SettingsNavigation()
        var presentations = 0
        let (window, host) = makeWindow(preferences: .shared, navigation: navigation, services: services,
                                        modelsAreReady: false, canShowTutorial: false) { presentations += 1 }
        defer { window.close() }
        let tutorial = try await settledControl("settingsTutorial", in: host, window: window)
        try click(at: tutorial.convert(NSPoint(x: tutorial.bounds.midX, y: tutorial.bounds.midY), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presentations, 0, "A disabled tutorial action must ignore clicks")
        navigation.selection = .models
        let check = try await settledControl("checkFileIntegrity", in: host, window: window)
        try click(at: check.convert(NSPoint(x: check.bounds.midX, y: check.bounds.midY), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(services.integrity.status, .idle)
        XCTAssertEqual(presentations, 0)
    }

    func testClosingTheIndependentSettingsWindowPreservesTheInteractiveWorkspace() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.openSample()
        try await waitFor("The existing workspace image must finish importing") { !workspace.isLoading }
        let image = try XCTUnwrap(workspace.selectedImage)
        workspace.options = ProcessingOptions(scale: 4, noise: 1)
        image.result = ProcessingResult(asset: image.input, options: workspace.options, duration: 0.1)
        workspace.zoom = 2.25
        workspace.preview = .compare
        workspace.split = 0.37
        workspace.activePanels = [.images, .options]
        let options = workspace.options
        let panels = workspace.activePanels
        let resultID = image.result?.asset.id
        let onboarding = OnboardingState(defaults: services.defaults)
        let (mainWindow, mainHost) = makeWorkspaceWindow(workspace: workspace, onboarding: onboarding)
        defer { mainWindow.close() }
        try await waitFor("The native image canvas must be mounted") {
            self.views(of: CanvasView.self, in: mainHost).first != nil
        }
        let canvas = try XCTUnwrap(views(of: CanvasView.self, in: mainHost).first)
        canvas.pan = CGSize(width: 73, height: -21)
        let pan = canvas.pan
        let frame = mainWindow.frame
        let viewport = mainHost.bounds
        let navigation = SettingsNavigation()
        navigation.selection = .about
        let (settingsWindow, settingsHost) = makeWindow(preferences: .shared, navigation: navigation, services: services)
        defer { settingsWindow.close() }
        try await waitFor("Settings must occupy its own compact window") {
            self.probe("settingsBounds", in: settingsHost) != nil
                && settingsHost.bounds.size == self.settingsSize
        }
        XCTAssertFalse(settingsWindow === mainWindow)
        XCTAssertTrue(settingsHost.window === settingsWindow)
        XCTAssertNil(mainWindow.attachedSheet)
        XCTAssertNil(settingsWindow.attachedSheet)
        XCTAssertNil(probe("settingsBounds", in: mainHost), "Settings must not cover the main workspace")
        XCTAssertEqual(mainWindow.frame, frame)
        XCTAssertEqual(mainHost.bounds, viewport)
        XCTAssertTrue(views(of: CanvasView.self, in: mainHost).first === canvas)
        XCTAssertTrue(canvas.isInteractionEnabled, "An independent settings window must not disable the main canvas")
        let controls = try XCTUnwrap(views(of: CanvasControlsHostView.self, in: mainHost).first)
        try await waitFor("Main-window preview and zoom controls remain enabled") {
            self.interactiveControls(in: controls.host).contains { $0.isEnabled }
        }

        settingsWindow.performClose(nil)
        try await waitFor("Native close must dismiss only the settings window") { !settingsWindow.isVisible }
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(mainWindow.frame, frame)
        XCTAssertEqual(mainHost.bounds, viewport)
        XCTAssertTrue(workspace.selectedImage === image)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertEqual(workspace.result?.asset.id, resultID)
        XCTAssertEqual(workspace.options, options)
        XCTAssertEqual(workspace.zoom, 2.25)
        XCTAssertEqual(workspace.preview, .compare)
        XCTAssertEqual(workspace.split, 0.37)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertTrue(views(of: CanvasView.self, in: mainHost).first === canvas)
        XCTAssertEqual(canvas.pan, pan)
        XCTAssertTrue(canvas.isInteractionEnabled)
        XCTAssertEqual(services.updates.status, .idle)
        XCTAssertEqual(services.integrity.status, .idle)
    }

    func testTutorialFromSettingsUsesTheExistingMainWindow() async throws {
        let services = try SettingsServices()
        defer { services.removeFixtures() }
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let onboarding = OnboardingState(defaults: services.defaults)
        let (mainWindow, mainHost) = makeWorkspaceWindow(workspace: workspace, onboarding: onboarding)
        defer { mainWindow.close() }
        let (settingsWindow, settingsHost) = makeWindow(preferences: .shared, navigation: SettingsNavigation(),
                                                       services: services) {
            onboarding.show()
            mainWindow.makeKeyAndOrderFront(nil)
        }
        defer { settingsWindow.close() }
        let existingWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let tutorial = try await settledControl("settingsTutorial", in: settingsHost, window: settingsWindow)
        try click(at: tutorial.convert(NSPoint(x: tutorial.bounds.midX, y: tutorial.bounds.midY), to: nil), in: settingsWindow)
        try await waitFor("The tutorial action must present in the existing main window") {
            onboarding.isPresented && self.probe("onboardingAnimationBounds", in: mainHost) != nil
        }
        XCTAssertEqual(onboarding.step, .addImages)
        XCTAssertTrue(mainHost.window === mainWindow)
        XCTAssertNil(mainWindow.attachedSheet)
        XCTAssertNil(probe("onboardingAnimationBounds", in: settingsHost))
        XCTAssertTrue(Set(NSApp.windows.map { ObjectIdentifier($0) }).subtracting(existingWindows).isEmpty)
        onboarding.complete()
        try await waitFor("Finishing the tutorial must restore the main workspace") {
            self.probe("onboardingAnimationBounds", in: mainHost) == nil
                && self.probe("queueToggleBounds", in: mainHost) != nil
        }
    }

    private func renderAllPanes(preferences: AppPreferences, services: SettingsServices,
                                language: String, scheme: ColorScheme) async throws {
        let navigation = SettingsNavigation()
        let (window, host) = makeWindow(preferences: preferences, navigation: navigation,
                                        services: services, scheme: scheme)
        defer { window.close() }
        var renderedPanes = Set<String>()
        for section in SettingsSection.allCases {
            navigation.selection = section
            try await waitFor("\(language) \(scheme) \(section.rawValue) must finish layout") {
                self.requiredIdentifiers(for: section).allSatisfy { self.probe($0, in: host) != nil }
            }
            window.setContentSize(settingsSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.size, settingsSize)
            let sidebarList = try XCTUnwrap(views(of: NSTableView.self, in: host).first {
                $0.numberOfRows == SettingsSection.allCases.count
            })
            let sidebarScroll = try XCTUnwrap(sidebarList.enclosingScrollView)
            let sidebar = sidebarScroll.convert(sidebarScroll.bounds, to: host)
            XCTAssertGreaterThanOrEqual(sidebar.width, 150)
            XCTAssertLessThan(sidebar.width, 230)
            for identifier in requiredIdentifiers(for: section) {
                let control = try XCTUnwrap(probe(identifier, in: host), identifier)
                let frame = control.convert(control.bounds, to: host)
                XCTAssertGreaterThan(frame.width, 20, identifier)
                XCTAssertGreaterThan(frame.height, 15, identifier)
                XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                              "\(language) \(section.rawValue): \(identifier) must fit the settings window: \(frame)")
                XCTAssertGreaterThanOrEqual(frame.minX, sidebar.maxX - 1,
                                           "Detail controls must remain clear of the native sidebar")
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 4_000, "The pane must render visible content")
            renderedPanes.insert(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
            if language == "en" || language == "zh-Hans" ||
                (section == .general && (language == "fr" || language == "ru")) {
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "settings-\(language)-\(scheme)-\(section.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(renderedPanes.count, 4, "Every settings selection must render its own content")
    }

    private func requiredIdentifiers(for section: SettingsSection) -> [String] {
        switch section {
        case .general: ["settingsLanguage", "settingsAppearance", "settingsCompletionNotification", "settingsPreventsSleep", "settingsTutorial"]
        case .models: ["settingsIntegrity", "checkFileIntegrity"]
        case .updates: ["settingsUpdates", "checkForUpdates"]
        case .about: ["settingsAbout", "settingsCopyDiagnostics"]
        }
    }

    private func makeWindow(preferences: AppPreferences, navigation: SettingsNavigation,
                             services: SettingsServices, scheme: ColorScheme = .light,
                             modelsAreReady: Bool = true, canShowTutorial: Bool = true,
                             onShowTutorial: @escaping () -> Void = {}) -> (NSWindow, NSHostingView<AnyView>) {
        let root = SettingsView(preferences: preferences, navigation: navigation, updates: services.updates,
                                integrity: services.integrity, modelsAreReady: modelsAreReady,
                                canShowTutorial: canShowTutorial, onShowTutorial: onShowTutorial,
                                workflow: ProcessingWorkflow(preferences: preferences, systemEffectsEnabled: false),
                                maintenance: services.maintenance)
            .environment(\.locale, preferences.locale)
            .environment(\.colorScheme, scheme)
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: settingsSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func makeWorkspaceWindow(workspace: Workspace, onboarding: OnboardingState)
        -> (NSWindow, NSHostingView<AnyView>) {
        let root = WorkspaceRootView(workspace: workspace, onboarding: onboarding, animates: false)
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: CanvasPanelLayout.minimumWindowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func makeFocusWindow(services: SettingsServices, navigation: SettingsNavigation? = nil) -> (SettingsFocusTestWindow, NSHostingView<AnyView>) {
        let root = SettingsView(preferences: .shared, navigation: navigation ?? SettingsNavigation(), updates: services.updates,
                                integrity: services.integrity, modelsAreReady: true,
                                canShowTutorial: true, onShowTutorial: {})
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        let window = SettingsFocusTestWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: settingsSize),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Do not depend on whichever application owns the foreground during
        // XCTest. The controlled key flag models only the focus transition.
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func nativeSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.contentView.map { self.probe("settingsBounds", in: $0) != nil } == true
        }
    }

    private func isCentered(_ settings: NSWindow, over main: NSWindow) -> Bool {
        abs(settings.frame.midX - main.frame.midX) <= 0.5
            && abs(settings.frame.midY - main.frame.midY) <= 0.5
    }

    private func performSettingsMenuAction() throws {
        func settingsItem(in menu: NSMenu) -> (NSMenu, Int)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent == ",",
                   item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command {
                    return (menu, index)
                }
                if let submenu = item.submenu, let result = settingsItem(in: submenu) { return result }
            }
            return nil
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let (owner, index) = try XCTUnwrap(settingsItem(in: menu), "The app must expose a Command-comma Settings menu item")
        XCTAssertTrue(owner.items[index].isEnabled)
        owner.performActionForItem(at: index)
    }

    private func probe(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.probe(identifier, in: $0) }.first
    }

    private func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(of: type, in: $0) }
    }

    private func interactiveControls(in view: NSView) -> [NSControl] {
        views(of: NSControl.self, in: view).filter { $0 is NSButton || $0 is NSSegmentedControl }
    }

    /// A representable can exist before Form layout and native toolbar sizing
    /// have settled. Send one click only after its window coordinates stay put.
    private func settledControl(_ identifier: String, in host: NSView, window: NSWindow) async throws -> NSView {
        let expectedSize = window.contentLayoutRect.size
        let deadline = Date().addingTimeInterval(3)
        var previousControlFrame: CGRect?
        var previousHostBounds: CGRect?
        var previousWindowFrame: CGRect?
        var previousContentLayout: CGRect?
        var stableSince = Date()
        window.makeKeyAndOrderFront(nil)
        while Date() < deadline {
            if window.contentLayoutRect.size != expectedSize { window.setContentSize(expectedSize) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let control = probe(identifier, in: host), control.window === window,
               host.window === window, window.isVisible,
               !control.isHiddenOrHasHiddenAncestor,
               control.bounds.width > 20, control.bounds.height > 15 {
                let frame = control.convert(control.bounds, to: nil)
                let hostFrame = control.convert(control.bounds, to: host)
                let fits = host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(hostFrame)
                let unchanged = frame == previousControlFrame && host.bounds == previousHostBounds
                    && window.frame == previousWindowFrame && window.contentLayoutRect == previousContentLayout
                if fits, unchanged, Date().timeIntervalSince(stableSince) >= 0.15 { return control }
                if !unchanged || !fits { stableSince = Date() }
                previousControlFrame = frame
                previousHostBounds = host.bounds
                previousWindowFrame = window.frame
                previousContentLayout = window.contentLayoutRect
            } else {
                stableSince = Date()
                previousControlFrame = nil
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let lastControl = probe(identifier, in: host)
        let message = "\(identifier) must have stable, visible bounds in its window before clicking"
            + " (control: \(String(describing: lastControl?.bounds)), host: \(host.bounds), key: \(window.isKeyWindow))"
        XCTFail(message)
        throw NSError(domain: "SettingsViewTests.LayoutTimeout", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func click(at point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message)
                throw NSError(domain: "SettingsViewTests.Timeout", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class SettingsFocusTestWindow: NSWindow {
    var simulatesKeyWindow = false
    override var isKeyWindow: Bool { simulatesKeyWindow }
}

@MainActor
private final class SettingsServices {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let updates: AppUpdateChecker
    let integrity: FileIntegrityChecker
    let maintenance: ModelMaintenance

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsViewTests-\(UUID().uuidString)")
        suiteName = "Waifu2x.SettingsViewTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        updates = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults, transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let paths = ModelPaths(root: directory.appendingPathComponent(ModelPaths.catalogVersion))
        let payload = Data("settings-integrity-fixture".utf8)
        let file = ModelCatalog.File(path: "fixture.onnx", bytes: Int64(payload.count),
                                     sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                                     sourceURL: URL(string: "https://models.example.invalid/fixture.onnx")!)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try payload.write(to: paths.root.appendingPathComponent(file.path))
        let catalog = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: [file])
        integrity = FileIntegrityChecker(catalog: catalog, paths: paths, signatureChecker: { _ in true })
        maintenance = ModelMaintenance(checker: integrity, catalog: catalog, paths: paths)
        maintenance.recordStartupReady()
    }

    func removeFixtures() {
        integrity.cancel()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
