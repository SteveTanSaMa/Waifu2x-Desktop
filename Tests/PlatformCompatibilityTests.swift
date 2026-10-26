import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import Waifu2x

@MainActor
final class PlatformCompatibilityTests: XCTestCase {
    func testVenturaDragBridgeAcceptsFirstMouseAndForwardsOnlyItsOwnDrag() throws {
        let view = WindowDragView()
        let window = CompatibilityDragWindow(contentRect: CGRect(x: 30, y: 30, width: 320, height: 100),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20),
                                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(view.acceptsFirstMouse(for: event))
        view.mouseDown(with: event)
        XCTAssertTrue(window.dragEvent === event)
        XCTAssertEqual(PlatformSymbols.name("waifu2x.missing.system.symbol", fallback: "rectangle.stack"), "rectangle.stack")
        XCTAssertEqual(PlatformSymbols.name("checkmark", fallback: "rectangle.stack"), "checkmark")
    }

    func testExistingSettingsPanesTranslateWithoutReplacingTheirHostOrSelection() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        preferences.languageCode = "en"
        let fixture = try CompatibilitySettingsFixture()
        defer { fixture.remove() }
        let navigation = SettingsNavigation()
        navigation.selection = .models
        let root = LiveSettingsLanguageView(preferences: preferences, navigation: navigation, fixture: fixture)
        let (window, host) = makeWindow(root, size: CGSize(width: 720, height: 520))
        defer { window.close() }

        try await waitForText(["Models ready to use"], in: host, message: "The initial model status must use English")
        let modelImage = try paneDigest(in: host)
        preferences.languageCode = "ja"
        try await waitForText(["モデルを使用できます"], in: host, message: "The existing model pane must translate its actual status text")
        XCTAssertNotEqual(try paneDigest(in: host), modelImage)
        XCTAssertEqual(navigation.selection, .models)
        XCTAssertTrue(host.window === window)
        XCTAssertTrue(window.contentView === host)
        XCTAssertEqual(fixture.integrity.status, .idle)

        navigation.selection = .about
        let japaneseVersion = AppLocalization(preferredLanguages: ["ja"]).string("版本 %@ · 构建 %@", arguments: [AppInformation.version, AppInformation.build])
        try await waitForText([japaneseVersion], in: host, message: "About must use the current language")
        try await wait("The existing About tagline must finish layout") { self.probe("settingsAboutTagline", in: host) != nil }
        let aboutImage = try taglineDigest(in: host)
        preferences.languageCode = "en"
        let englishVersion = AppLocalization(preferredLanguages: ["en"]).string("版本 %@ · 构建 %@", arguments: [AppInformation.version, AppInformation.build])
        try await waitForText([englishVersion], in: host, message: "The mounted About pane must translate without a new window")
        // Static SwiftUI Text in a ScrollView is not always materialized in the
        // self-process AX tree. Inspect its rendered glyph region separately
        // from the native, selectable version field used above.
        try await wait("The existing About tagline glyphs must change language") {
            (try? self.taglineDigest(in: host)) != aboutImage
        }
        XCTAssertNotEqual(try taglineDigest(in: host), aboutImage)
        XCTAssertEqual(navigation.selection, .about)
        XCTAssertTrue(host.window === window)
        XCTAssertTrue(window.contentView === host)
        XCTAssertEqual(fixture.updates.status, .idle)
    }

    func testExistingWorkspaceTranslatesAndKeepsCanvasQueueResultsAndViewState() async throws {
        let preferences = AppPreferences.shared
        let previousLanguage = preferences.languageCode
        defer { preferences.languageCode = previousLanguage }
        preferences.languageCode = "en"
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.openSample()
        try await wait("The generated sample must import without running a model") { !workspace.isLoading }
        let image = try XCTUnwrap(workspace.selectedImage)
        workspace.options = ProcessingOptions(scale: 4, noise: 1)
        image.result = ProcessingResult(asset: image.input, options: workspace.options, duration: 0.1)
        workspace.zoom = 2.25
        workspace.preview = .compare
        workspace.split = 0.37
        workspace.activePanels = [.images, .options]
        let options = workspace.options
        let resultID = image.result?.asset.id
        let panels = workspace.activePanels
        let resetID = workspace.viewResetID
        let root = LiveWorkspaceLanguageView(preferences: preferences, workspace: workspace)
        let (window, host) = makeWindow(root, size: CanvasPanelLayout.minimumWindowSize)
        defer { window.close() }
        try await waitForText(["Enhance"], in: host, message: "The existing Enhance action must be exposed in English")
        try await wait("The existing canvas must be mounted") { self.views(of: CanvasView.self, in: host).count == 1 }
        let canvas = try XCTUnwrap(views(of: CanvasView.self, in: host).first)
        // Set pan after the first viewport layout, as an actual user would.
        try await Task.sleep(for: .milliseconds(100))
        canvas.pan = CGSize(width: 73, height: -21)
        let pan = canvas.pan
        preferences.languageCode = "ja"
        try await waitForText(["高画質化"], in: host, message: "The already mounted workspace action must translate")
        XCTAssertTrue(window.contentView === host)
        XCTAssertTrue(host.window === window)
        XCTAssertTrue(views(of: CanvasView.self, in: host).first === canvas)
        XCTAssertEqual(canvas.pan, pan)
        XCTAssertTrue(workspace.selectedImage === image)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertEqual(workspace.result?.asset.id, resultID)
        XCTAssertEqual(workspace.options, options)
        XCTAssertEqual(workspace.zoom, 2.25)
        XCTAssertEqual(workspace.preview, .compare)
        XCTAssertEqual(workspace.split, 0.37)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertEqual(workspace.viewResetID, resetID)
    }

    func testOptionalObservedObjectFollowsMutationNilAndReplacement() async throws {
        let first = CompatibilityObservedService(value: 1)
        let holder = CompatibilityServiceHolder(service: first)
        let (window, host) = makeWindow(OptionalServiceParent(holder: holder), size: CGSize(width: 320, height: 120))
        defer { window.close() }
        try await wait("An injected optional service must render") { self.probe("service-1", in: host) != nil }
        first.value = 2
        try await wait("Mutating the injected service must invalidate the existing view") {
            self.probe("service-2", in: host) != nil
        }
        holder.service = nil
        try await wait("Removing a service must detach the old observation") {
            self.probe("service-none", in: host) != nil
        }
        let replacement = CompatibilityObservedService(value: 7)
        holder.service = replacement
        try await wait("A replacement service must be observed") { self.probe("service-7", in: host) != nil }
        replacement.value = 8
        try await wait("The replacement publisher must drive the same host") { self.probe("service-8", in: host) != nil }
        first.value = 99
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(probe("service-8", in: host))
        XCTAssertNil(probe("service-99", in: host))
        XCTAssertTrue(window.contentView === host)
    }

    private func makeWindow<Content: View>(_ content: Content, size: CGSize) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(content.transaction { $0.animation = nil }))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 60, y: 60), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func paneDigest(in host: NSView) throws -> SHA256.Digest {
        host.layoutSubtreeIfNeeded()
        // Exclude the native sidebar so a translated section title alone cannot
        // make an unchanged detail pane pass this check.
        let rect = CGRect(x: 185, y: 0, width: host.bounds.width - 185, height: host.bounds.height)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return SHA256.hash(data: data)
    }

    private func taglineDigest(in host: NSView) throws -> SHA256.Digest {
        host.layoutSubtreeIfNeeded()
        let probe = try XCTUnwrap(probe("settingsAboutTagline", in: host))
        let bounds = probe.convert(probe.bounds, to: host)
        XCTAssertGreaterThan(bounds.height, 10)
        let rect = CGRect(x: 185, y: bounds.minY - 2, width: host.bounds.width - 185, height: bounds.height + 4)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return SHA256.hash(data: data)
    }

    private func accessibleStrings(_ view: NSView) -> Set<String> {
        var strings = Set<String>()
        var visited = Set<ObjectIdentifier>()
        func collect(_ value: AnyObject, depth: Int) {
            guard depth < 40, let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector),
                   let text = object.perform(selector)?.takeUnretainedValue() as? String {
                    strings.insert(text)
                }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector),
               let children = object.perform(selector)?.takeUnretainedValue() as? [AnyObject] {
                children.forEach { collect($0, depth: depth + 1) }
            }
            if let native = object as? NSView { native.subviews.forEach { collect($0, depth: depth + 1) } }
        }
        collect(view, depth: 0)
        return strings
    }

    private func waitForText(_ expected: Set<String>, in host: NSView, message: String) async throws {
        do {
            try await wait(message) {
                let strings = self.accessibleStrings(host)
                // SwiftUI may combine adjacent text and a button's shortcut in
                // one accessibility element, while preserving the body copy.
                return expected.allSatisfy { phrase in strings.contains { $0.contains(phrase) } }
            }
        } catch {
            print("Compatibility AX text for \(message): \(accessibleStrings(host).sorted())")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = message
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            throw error
        }
    }

    private func probe(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.probe(identifier, in: $0) }.first
    }

    private func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(of: type, in: $0) }
    }

    private func wait(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message)
                throw NSError(domain: "PlatformCompatibilityTests.Timeout", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct LiveSettingsLanguageView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var navigation: SettingsNavigation
    let fixture: CompatibilitySettingsFixture
    var body: some View {
        SettingsView(preferences: preferences, navigation: navigation, updates: fixture.updates,
                     integrity: fixture.integrity, modelsAreReady: true, canShowTutorial: false,
                     onShowTutorial: {}, maintenance: fixture.maintenance)
            .environment(\.locale, preferences.locale)
    }
}

private struct LiveWorkspaceLanguageView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var workspace: Workspace
    var body: some View {
        ContentView(workspace: workspace).environment(\.locale, preferences.locale)
    }
}

@MainActor
private final class CompatibilitySettingsFixture {
    let directory: URL
    let integrity: FileIntegrityChecker
    let maintenance: ModelMaintenance
    let updates: AppUpdateChecker
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompatibilitySettings-\(UUID())")
        let paths = ModelPaths(root: directory.appendingPathComponent(ModelPaths.catalogVersion))
        let data = Data("macOS 13 compatibility fixture".utf8)
        let file = ModelCatalog.File(path: "fixture.onnx", bytes: Int64(data.count),
                                     sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                     sourceURL: URL(string: "https://example.invalid/fixture.onnx")!)
        let catalog = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: [file])
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try data.write(to: paths.root.appendingPathComponent(file.path))
        integrity = FileIntegrityChecker(catalog: catalog, paths: paths, signatureChecker: { _ in true })
        maintenance = ModelMaintenance(checker: integrity, catalog: catalog, paths: paths)
        maintenance.recordStartupReady()
        updates = AppUpdateChecker(transport: { _ in throw URLError(.notConnectedToInternet) })
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class CompatibilityObservedService: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

private final class CompatibilityServiceHolder: ObservableObject {
    @Published var service: CompatibilityObservedService?
    init(service: CompatibilityObservedService?) { self.service = service }
}

private struct OptionalServiceParent: View {
    @ObservedObject var holder: CompatibilityServiceHolder
    var body: some View { OptionalServiceProbe(service: holder.service) }
}

private struct OptionalServiceProbe: View {
    @OptionalObservedObject var service: CompatibilityObservedService?
    var body: some View {
        Text(verbatim: service.map { String($0.value) } ?? "none")
            .background(HeaderGeometryReader(identifier: "service-\(service.map { String($0.value) } ?? "none")"))
    }
}

@MainActor
private final class CompatibilityDragWindow: NSWindow {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}
