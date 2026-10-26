import Combine
import Foundation
import XCTest
@testable import Waifu2x

@MainActor
final class ObservableGraphTests: XCTestCase {
    func testQueueResultStateChangesInvalidateTheWorkspaceWithoutReplacingItsImages() async throws {
        let workspace = Workspace(persistOptions: false)
        workspace.openSample()
        try await wait { !workspace.isLoading }
        let image = try XCTUnwrap(workspace.selectedImage)
        let changes = GraphChangeCounter()
        let subscription = workspace.objectWillChange.sink { changes.increment() }
        defer { subscription.cancel() }
        image.state = .failed
        image.failure = "fixture failure"
        XCTAssertGreaterThan(changes.value, 0)
        XCTAssertTrue(workspace.selectedImage === image)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertEqual(workspace.selectedImage?.state, .failed)
    }

    func testRepairAndInferenceAvailabilityRefreshBothWaysWithoutAnObservationCycle() async throws {
        let fixture = try ModelMaintenanceTests.Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let workspace = Workspace(persistOptions: false)
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, canRepair: { !workspace.busy })
        workspace.canStartProcessing = { [weak maintenance] in maintenance?.modelsCanBeUsed == true }
        workspace.observeProcessingAvailability(maintenance.objectWillChange)
        maintenance.observeRepairAvailability(workspace)
        maintenance.recordStartupReady()
        try fixture.removeModel(1)
        checker.check()
        await checker.waitUntilFinished()
        XCTAssertTrue(maintenance.canStartRepair)
        let workspaceChanges = GraphChangeCounter()
        let maintenanceChanges = GraphChangeCounter()
        let first = workspace.objectWillChange.sink { workspaceChanges.increment() }
        let second = maintenance.objectWillChange.sink { maintenanceChanges.increment() }
        defer { first.cancel(); second.cancel() }

        workspace.isProcessing = true
        XCTAssertFalse(maintenance.canStartRepair)
        XCTAssertGreaterThan(maintenanceChanges.value, 0)
        XCTAssertLessThan(workspaceChanges.value, 5, "The two availability dependencies must not recursively publish")
        workspace.isProcessing = false
        XCTAssertTrue(maintenance.canStartRepair)
        workspace.isExporting = true
        XCTAssertFalse(maintenance.canStartRepair)
        workspace.isExporting = false
        XCTAssertTrue(maintenance.canStartRepair)
    }

    func testUpdateDownloadChangesInvalidateTheUpdatePageOwner() async throws {
        let downloader = AppUpdateDownloader(currentVersion: "1.0.2", currentBuild: "3",
                                             transport: { _ in throw URLError(.notConnectedToInternet) })
        let checker = AppUpdateChecker(currentVersion: "1.0.2", downloader: downloader)
        let changes = GraphChangeCounter()
        let subscription = checker.objectWillChange.sink { changes.increment() }
        defer { subscription.cancel() }
        downloader.start(.init(version: "1.0.3", url: URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v1.0.3")!,
                               hasUpdateCatalog: true))
        try await wait { downloader.status == .failed }
        XCTAssertGreaterThan(changes.value, 0)
        XCTAssertEqual(checker.status, .idle, "Forwarding download changes must not start another update check")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { throw AppFailure.message("Observable graph test timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class GraphChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
