import AppKit
import IOKit.pwr_mgt
import Observation
import UserNotifications

enum CompletionNotificationAuthorization: Equatable { case notDetermined, allowed, denied }

struct ProcessingCompletionMessage: Equatable, Sendable {
    let title: String
    let body: String
}

@MainActor
protocol ProcessingNotificationClient {
    func authorization() async -> CompletionNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func send(_ message: ProcessingCompletionMessage, identifier: String) async throws
}

protocol ProcessingPowerAssertion: AnyObject, Sendable {
    func release()
}

/// The worker owns this lease until run() returns, even when its parent task is
/// cancelled. Display sleep and explicit system sleep remain available.
final class ProcessingSleepLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let makeAssertion: @Sendable () -> (any ProcessingPowerAssertion)?
    private var assertion: (any ProcessingPowerAssertion)?
    private var finished = false

    init(enabled: Bool, makeAssertion: @escaping @Sendable () -> (any ProcessingPowerAssertion)?) {
        self.makeAssertion = makeAssertion
        if enabled { assertion = makeAssertion() }
    }

    func setEnabled(_ enabled: Bool) {
        let previous: (any ProcessingPowerAssertion)? = lock.withLock {
            guard !finished else { return nil }
            if enabled {
                if assertion == nil { assertion = makeAssertion() }
                return nil
            }
            let previous = assertion
            assertion = nil
            return previous
        }
        previous?.release()
    }

    func finish() {
        let previous = lock.withLock {
            finished = true
            let previous = assertion
            assertion = nil
            return previous
        }
        previous?.release()
    }

    deinit { finish() }
}

/// App-owned so an authorization request survives the settings window closing.
/// Workspace drives inference leases and reports the final batch outcome.
@MainActor @Observable
final class ProcessingWorkflow {
    private enum NotificationIssue { case denied, unavailable }
    private var notificationIssue: NotificationIssue?
    var notificationStatus: String? {
        guard let notificationIssue else { return nil }
        let key: String
        switch notificationIssue {
        case .denied: key = "通知未获允许，可在系统设置中开启"
        case .unavailable: key = "暂时无法启用通知，请稍后重试"
        }
        return preferences.localizer.string(key)
    }
    private(set) var isRequestingNotificationPermission = false
    let preferences: AppPreferences
    @ObservationIgnored private let notifications: (any ProcessingNotificationClient)?
    @ObservationIgnored private let makeAssertion: @Sendable () -> (any ProcessingPowerAssertion)?
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private var leases: [UUID: ProcessingSleepLease] = [:]
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reportedBatches: Set<UUID> = []
    @ObservationIgnored private var permissionIntent = UUID()
    @ObservationIgnored private var isShuttingDown = false

    nonisolated static var systemEffectsEnabled: Bool {
        let process = ProcessInfo.processInfo
        return !process.arguments.contains("--isolated-session")
            && process.environment["XCTestConfigurationFilePath"] == nil
            && (process.environment["WAIFU2X_TEST_MODE"] ?? "").isEmpty
            && NSClassFromString("XCTestCase") == nil
    }

    init(preferences: AppPreferences, systemEffectsEnabled: Bool = ProcessingWorkflow.systemEffectsEnabled,
         notifications: (any ProcessingNotificationClient)? = nil,
         makeAssertion: (@Sendable () -> (any ProcessingPowerAssertion)?)? = nil,
         isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }) {
        self.preferences = preferences
        self.notifications = notifications ?? (systemEffectsEnabled ? SystemProcessingNotifications() : nil)
        if let makeAssertion { self.makeAssertion = makeAssertion }
        else if systemEffectsEnabled { self.makeAssertion = { SystemProcessingPowerAssertion() } }
        else { self.makeAssertion = { nil } }
        self.isAppActive = isAppActive
        observeSleepPreference()
    }

    func setPreventsSleepWhileProcessing(_ enabled: Bool) {
        preferences.preventsSleepWhileProcessing = enabled
        updateSleepLeases()
    }

    func setNotifiesOnCompletion(_ enabled: Bool) {
        permissionIntent = UUID()
        permissionTask?.cancel()
        permissionTask = nil
        isRequestingNotificationPermission = false
        notificationIssue = nil
        guard enabled, !isShuttingDown else {
            preferences.notifiesOnCompletion = false
            return
        }
        // The toggle stays off until authorization succeeds. No permission
        // request is issued by initialization or a batch finishing.
        preferences.notifiesOnCompletion = false
        guard let notifications else {
            notificationIssue = .unavailable
            return
        }
        let intent = permissionIntent
        isRequestingNotificationPermission = true
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let status = await notifications.authorization()
            guard self.permissionIntent == intent, !self.isShuttingDown, !Task.isCancelled else { return }
            do {
                let allowed: Bool
                switch status {
                case .allowed: allowed = true
                case .denied: allowed = false
                case .notDetermined: allowed = try await notifications.requestAuthorization()
                }
                guard self.permissionIntent == intent, !self.isShuttingDown, !Task.isCancelled else { return }
                self.preferences.notifiesOnCompletion = allowed
                self.notificationIssue = allowed ? nil : .denied
            } catch {
                guard self.permissionIntent == intent, !self.isShuttingDown, !Task.isCancelled else { return }
                self.preferences.notifiesOnCompletion = false
                self.notificationIssue = .unavailable
            }
            self.isRequestingNotificationPermission = false
            self.permissionTask = nil
        }
    }

    func beginInference() -> ProcessingSleepLease {
        let lease = ProcessingSleepLease(enabled: !isShuttingDown && preferences.preventsSleepWhileProcessing, makeAssertion: makeAssertion)
        leases[lease.id] = lease
        return lease
    }

    func endInference(_ lease: ProcessingSleepLease) {
        lease.finish()
        leases.removeValue(forKey: lease.id)
    }

    func completeBatch(id: UUID, count: Int, succeeded: Int, failed: Int, cancelled: Bool) {
        guard !isShuttingDown, !cancelled, count > 1, succeeded + failed == count,
              preferences.notifiesOnCompletion, !isAppActive(),
              !reportedBatches.contains(id), let notifications else { return }
        reportedBatches.insert(id)
        let localizer = preferences.localizer
        let body = failed > 0
            ? localizer.string("%d 张增强完成，%d 张未能完成", arguments: [succeeded, failed])
            : localizer.string("%d 张图片已增强完成", arguments: [succeeded])
        let message = ProcessingCompletionMessage(title: localizer.string("批量增强已结束"), body: body)
        deliveryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTasks.removeValue(forKey: id) }
            let authorization = await notifications.authorization()
            guard !Task.isCancelled, !self.isShuttingDown, self.preferences.notifiesOnCompletion, !self.isAppActive() else { return }
            guard authorization == .allowed else {
                self.preferences.notifiesOnCompletion = false
                self.notificationIssue = .denied
                return
            }
            // Only aggregate counts are included. Input names and paths never
            // enter the notification center or lock-screen payload.
            try? await notifications.send(message, identifier: "processing-\(id.uuidString)")
        }
    }

    func shutdown() {
        isShuttingDown = true
        permissionIntent = UUID()
        permissionTask?.cancel()
        permissionTask = nil
        isRequestingNotificationPermission = false
        for task in deliveryTasks.values { task.cancel() }
        deliveryTasks.removeAll()
        // Active workers retain their leases until they return. Releasing here
        // could let the machine idle-sleep while cancellation is still running.
    }

    private func observeSleepPreference() {
        withObservationTracking {
            _ = preferences.preventsSleepWhileProcessing
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateSleepLeases()
                self.observeSleepPreference()
            }
        }
    }

    private func updateSleepLeases() {
        for lease in leases.values { lease.setEnabled(preferences.preventsSleepWhileProcessing) }
    }
}

@MainActor
private final class SystemProcessingNotifications: ProcessingNotificationClient {
    private let center = UNUserNotificationCenter.current()

    func authorization() async -> CompletionNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(_ message: ProcessingCompletionMessage, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

private final class SystemProcessingPowerAssertion: ProcessingPowerAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: IOPMAssertionID?

    init?() {
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Waifu2x image processing" as CFString, &identifier)
        guard result == kIOReturnSuccess else { return nil }
        self.identifier = identifier
    }

    func release() {
        let current = lock.withLock {
            let current = identifier
            identifier = nil
            return current
        }
        if let current { IOPMAssertionRelease(current) }
    }

    deinit { release() }
}
