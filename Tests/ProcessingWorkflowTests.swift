import AppKit
import XCTest
@testable import Waifu2x

@MainActor
final class ProcessingWorkflowTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { throw AppFailure.message("Workflow test timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func workflow(_ preferences: AppPreferences, notifications: WorkflowNotificationSpy? = nil,
                          power: WorkflowPowerSpy = WorkflowPowerSpy(), active: @escaping @MainActor () -> Bool = { false }) -> ProcessingWorkflow {
        ProcessingWorkflow(preferences: preferences, systemEffectsEnabled: false, notifications: notifications ?? WorkflowNotificationSpy(),
                           makeAssertion: { power.make() }, isAppActive: active)
    }

    func testPermissionIsRequestedOnlyAfterEnablingAndDenialIsRemembered() async throws {
        let preferences = AppPreferences(defaults: nil)
        let notifications = WorkflowNotificationSpy()
        notifications.decision = false
        let workflow = workflow(preferences, notifications: notifications)
        XCTAssertEqual(notifications.requests, 0)
        XCTAssertFalse(preferences.notifiesOnCompletion)
        workflow.setNotifiesOnCompletion(true)
        try await waitUntil { !workflow.isRequestingNotificationPermission }
        XCTAssertEqual(notifications.requests, 1)
        XCTAssertFalse(preferences.notifiesOnCompletion)
        XCTAssertNotNil(workflow.notificationStatus)
        workflow.setNotifiesOnCompletion(true)
        try await waitUntil { !workflow.isRequestingNotificationPermission }
        XCTAssertEqual(notifications.requests, 1)
        XCTAssertFalse(preferences.notifiesOnCompletion)
    }

    func testDisablingDuringPermissionRequestCannotReenablePreference() async throws {
        let preferences = AppPreferences(defaults: nil)
        let notifications = WorkflowNotificationSpy()
        notifications.decision = nil
        let workflow = workflow(preferences, notifications: notifications)
        workflow.setNotifiesOnCompletion(true)
        try await waitUntil { notifications.requests == 1 }
        workflow.setNotifiesOnCompletion(false)
        notifications.resolvePermission(true)
        await Task.yield()
        XCTAssertFalse(preferences.notifiesOnCompletion)
        XCTAssertFalse(workflow.isRequestingNotificationPermission)
    }

    func testExistingNotificationStatusFollowsLanguageChanges() async throws {
        let preferences = AppPreferences(defaults: nil, systemLanguages: ["en"])
        let notifications = WorkflowNotificationSpy()
        notifications.status = .denied
        let workflow = workflow(preferences, notifications: notifications)
        workflow.setNotifiesOnCompletion(true)
        try await waitUntil { !workflow.isRequestingNotificationPermission }
        let english = try XCTUnwrap(workflow.notificationStatus)
        XCTAssertEqual(english, preferences.localizer.string("通知未获允许，可在系统设置中开启"))
        preferences.languageCode = "ja"
        XCTAssertEqual(workflow.notificationStatus, preferences.localizer.string("通知未获允许，可在系统设置中开启"))
        XCTAssertNotEqual(workflow.notificationStatus, english)
        XCTAssertEqual(notifications.requests, 0)
    }

    func testAlreadyAuthorizedPreferenceEnablesWithoutRequestingPermission() async throws {
        let preferences = AppPreferences(defaults: nil)
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let workflow = workflow(preferences, notifications: notifications)
        workflow.setNotifiesOnCompletion(true)
        try await waitUntil { !workflow.isRequestingNotificationPermission }
        XCTAssertTrue(preferences.notifiesOnCompletion)
        XCTAssertEqual(notifications.requests, 0)
        XCTAssertNil(workflow.notificationStatus)
    }

    func testOnlyFinishedBackgroundBatchesNotifyAndDuplicateCompletionsAreIgnored() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        var isActive = true
        let workflow = workflow(preferences, notifications: notifications, active: { isActive })
        workflow.completeBatch(id: UUID(), count: 2, succeeded: 2, failed: 0, cancelled: false)
        isActive = false
        workflow.completeBatch(id: UUID(), count: 1, succeeded: 1, failed: 0, cancelled: false)
        workflow.completeBatch(id: UUID(), count: 2, succeeded: 1, failed: 0, cancelled: true)
        workflow.completeBatch(id: UUID(), count: 2, succeeded: 1, failed: 0, cancelled: false)
        await Task.yield()
        XCTAssertTrue(notifications.messages.isEmpty)
        let id = UUID()
        workflow.completeBatch(id: id, count: 3, succeeded: 2, failed: 1, cancelled: false)
        workflow.completeBatch(id: id, count: 3, succeeded: 2, failed: 1, cancelled: false)
        try await waitUntil { notifications.messages.count == 1 }
        XCTAssertEqual(notifications.messages[0].body, preferences.localizer.string("%d 张增强完成，%d 张未能完成", arguments: [2, 1]))
        XCTAssertEqual(notifications.requests, 0)
    }

    func testRevokedPermissionDisablesPreferenceWithoutAnotherPrompt() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .denied
        let workflow = workflow(preferences, notifications: notifications)
        workflow.completeBatch(id: UUID(), count: 2, succeeded: 2, failed: 0, cancelled: false)
        try await waitUntil { !preferences.notifiesOnCompletion }
        XCTAssertTrue(notifications.messages.isEmpty)
        XCTAssertEqual(notifications.requests, 0)
        XCTAssertNotNil(workflow.notificationStatus)
    }

    func testAllFailedBatchReportsNoSuccesses() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let workflow = workflow(preferences, notifications: notifications)
        workflow.completeBatch(id: UUID(), count: 2, succeeded: 0, failed: 2, cancelled: false)
        try await waitUntil { notifications.messages.count == 1 }
        XCTAssertEqual(notifications.messages[0].body, preferences.localizer.string("%d 张增强完成，%d 张未能完成", arguments: [0, 2]))
    }

    func testSleepLeaseCanToggleAndWorkerFinishingIsIdempotent() {
        let preferences = AppPreferences(defaults: nil)
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, power: power)
        let lease = workflow.beginInference()
        XCTAssertEqual(power.active, 1)
        workflow.setPreventsSleepWhileProcessing(false)
        XCTAssertEqual(power.active, 0)
        workflow.setPreventsSleepWhileProcessing(true)
        XCTAssertEqual(power.active, 1)
        lease.finish()
        workflow.endInference(lease)
        workflow.setPreventsSleepWhileProcessing(true)
        XCTAssertEqual(power.active, 0)
        XCTAssertEqual(power.created, power.released)
    }

    func testDirectSleepPreferenceChangeUpdatesRunningLease() async throws {
        let preferences = AppPreferences(defaults: nil)
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, power: power)
        let lease = workflow.beginInference()
        preferences.preventsSleepWhileProcessing = false
        try await waitUntil { power.active == 0 }
        preferences.preventsSleepWhileProcessing = true
        try await waitUntil { power.active == 1 }
        workflow.endInference(lease)
        XCTAssertEqual(power.active, 0)
    }

    func testQueuePartialFailureReportsCountsAndReleasesEveryAssertion() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, notifications: notifications, power: power)
        let workers = [WorkflowInferenceSpy(), WorkflowInferenceSpy(fails: true)]
        var next = 0
        let workspace = Workspace(persistOptions: false, workflow: workflow, makeInference: {
            defer { next += 1 }
            return workers[next]
        })
        defer { workspace.shutdown() }
        try addImages(to: workspace, count: 2)
        workspace.processAll()
        try await waitUntil { !workspace.isProcessing && notifications.messages.count == 1 }
        XCTAssertEqual(workspace.images.map(\.state), [.completed, .failed])
        XCTAssertEqual(notifications.messages[0].body, preferences.localizer.string("%d 张增强完成，%d 张未能完成", arguments: [1, 1]))
        XCTAssertEqual(power.created, 2)
        XCTAssertEqual(power.active, 0)
        XCTAssertFalse(notifications.messages[0].body.contains("private-input"))
    }

    func testCancelKeepsLeaseUntilWorkerReturnsAndNeverNotifies() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, notifications: notifications, power: power)
        let worker = WorkflowInferenceSpy(blocked: true)
        defer { worker.resume() }
        let workspace = Workspace(persistOptions: false, workflow: workflow, makeInference: { worker })
        defer { workspace.shutdown() }
        try addImages(to: workspace, count: 2)
        workspace.processAll()
        try await waitUntil { worker.hasStarted }
        workspace.cancel()
        XCTAssertTrue(workspace.isProcessing)
        XCTAssertEqual(power.active, 1)
        worker.resume()
        try await waitUntil { !workspace.isProcessing }
        XCTAssertEqual(workspace.images.map(\.state), [.cancelled, .ready])
        XCTAssertEqual(power.active, 0)
        XCTAssertTrue(notifications.messages.isEmpty)
    }

    func testRestartWaitsForOldWorkerAndNotifiesOnlyReplacementBatch() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, notifications: notifications, power: power)
        let oldWorker = WorkflowInferenceSpy(blocked: true)
        defer { oldWorker.resume() }
        let workers = [oldWorker, WorkflowInferenceSpy(), WorkflowInferenceSpy()]
        var next = 0
        let workspace = Workspace(persistOptions: false, workflow: workflow, makeInference: {
            defer { next += 1 }
            return workers[next]
        })
        defer { workspace.shutdown() }
        try addImages(to: workspace, count: 2)
        workspace.processAll()
        try await waitUntil { oldWorker.hasStarted }
        workspace.processAll()
        workspace.confirmRestart()
        XCTAssertEqual(next, 1)
        XCTAssertEqual(power.active, 1)
        oldWorker.resume()
        try await waitUntil { !workspace.isProcessing && notifications.messages.count == 1 }
        XCTAssertEqual(next, 3)
        XCTAssertEqual(power.maximumActive, 1)
        XCTAssertEqual(power.active, 0)
        XCTAssertEqual(workspace.completedImages.count, 2)
        XCTAssertEqual(notifications.messages[0].body, preferences.localizer.string("%d 张图片已增强完成", arguments: [2]))
    }

    func testTerminationAwaitsWorkerBeforeReleasingLeaseAndRemovingScratchDirectory() async throws {
        let preferences = AppPreferences(defaults: nil)
        preferences.notifiesOnCompletion = true
        let notifications = WorkflowNotificationSpy()
        notifications.status = .allowed
        let power = WorkflowPowerSpy()
        let workflow = workflow(preferences, notifications: notifications, power: power)
        let worker = WorkflowInferenceSpy(blocked: true)
        defer { worker.resume() }
        let workspace = Workspace(persistOptions: false, workflow: workflow, makeInference: { worker })
        try addImages(to: workspace, count: 2)
        workspace.processAll()
        try await waitUntil { worker.hasStarted }
        var terminated = false
        let termination = Task { await workspace.prepareForTermination(); terminated = true }
        try await waitUntil { worker.wasCancelled }
        XCTAssertFalse(terminated)
        XCTAssertEqual(power.active, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.directory.path))
        worker.resume()
        await termination.value
        XCTAssertEqual(power.active, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.directory.path))
        XCTAssertTrue(notifications.messages.isEmpty)
    }

    func testMaintenanceGateBlocksEveryProcessingEntry() throws {
        var createdWorkers = 0
        let workspace = Workspace(persistOptions: false, makeInference: { createdWorkers += 1; return WorkflowInferenceSpy() })
        defer { workspace.shutdown() }
        try addImages(to: workspace, count: 2)
        workspace.canStartProcessing = { false }
        XCTAssertFalse(workspace.canProcessSelection)
        workspace.process()
        workspace.processAll()
        workspace.processPending()
        workspace.confirmRestart()
        XCTAssertFalse(workspace.isProcessing)
        XCTAssertEqual(createdWorkers, 0)
    }

    func testMaintenanceGateIsRecheckedBeforePendingRestartBegins() async throws {
        let worker = WorkflowInferenceSpy(blocked: true)
        defer { worker.resume() }
        var createdWorkers = 0
        var permitsProcessing = true
        let workspace = Workspace(persistOptions: false, makeInference: { createdWorkers += 1; return worker })
        defer { workspace.shutdown() }
        workspace.canStartProcessing = { permitsProcessing }
        try addImages(to: workspace, count: 2)
        workspace.processAll()
        try await waitUntil { worker.hasStarted }
        workspace.processAll()
        workspace.confirmRestart()
        permitsProcessing = false
        worker.resume()
        try await waitUntil { !workspace.isProcessing }
        XCTAssertEqual(createdWorkers, 1)
        XCTAssertFalse(workspace.canProcessSelection)
    }

    private func addImages(to workspace: Workspace, count: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for index in 0..<count {
            let url = workspace.directory.appendingPathComponent("private-input-\(index).png")
            try ImageCodec.writePNG(image, to: url)
            workspace.images.append(QueueImage(input: ImageAsset(url: url, image: image, name: url.lastPathComponent)))
        }
        if let first = workspace.images.first { workspace.select(first) }
    }
}

@MainActor
private final class WorkflowNotificationSpy: ProcessingNotificationClient {
    var status: CompletionNotificationAuthorization = .notDetermined
    var decision: Bool? = true
    var requests = 0
    var messages: [ProcessingCompletionMessage] = []
    private var continuation: CheckedContinuation<Bool, Never>?
    func authorization() async -> CompletionNotificationAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        let allowed: Bool
        if let decision { allowed = decision }
        else { allowed = await withCheckedContinuation { continuation = $0 } }
        status = allowed ? .allowed : .denied
        return allowed
    }
    func resolvePermission(_ allowed: Bool) { continuation?.resume(returning: allowed); continuation = nil }
    func send(_ message: ProcessingCompletionMessage, identifier: String) async throws { messages.append(message) }
}

private final class WorkflowPowerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (created: 0, released: 0, maximumActive: 0)
    var created: Int { lock.withLock { counts.created } }
    var released: Int { lock.withLock { counts.released } }
    var active: Int { lock.withLock { counts.created - counts.released } }
    var maximumActive: Int { lock.withLock { counts.maximumActive } }
    func make() -> any ProcessingPowerAssertion {
        lock.withLock {
            counts.created += 1
            counts.maximumActive = max(counts.maximumActive, counts.created - counts.released)
        }
        return WorkflowPowerToken { [self] in lock.withLock { counts.released += 1 } }
    }
}

private final class WorkflowPowerToken: ProcessingPowerAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?
    init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    func release() {
        let callback = lock.withLock { let callback = onRelease; onRelease = nil; return callback }
        callback?()
    }
    deinit { release() }
}

private final class WorkflowInferenceSpy: WorkspaceInference, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: DispatchSemaphore?
    private let fails: Bool
    private var started = false
    private var cancelled = false
    var hasStarted: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    init(blocked: Bool = false, fails: Bool = false) { gate = blocked ? DispatchSemaphore(value: 0) : nil; self.fails = fails }
    func cancel() { lock.withLock { cancelled = true } }
    func resume() { gate?.signal() }
    func run(input: ImageAsset, options: ProcessingOptions, directory: URL,
             progress: @escaping @Sendable (TileProgress) -> Void, stage: @escaping @Sendable (String) -> Void) throws -> URL {
        lock.withLock { started = true }
        gate?.wait()
        if wasCancelled { throw CancellationError() }
        if fails { throw AppFailure.message("Injected inference failure") }
        let output = directory.appendingPathComponent("mock-result-\(UUID().uuidString).png")
        try FileManager.default.copyItem(at: input.url, to: output)
        return output
    }
}
