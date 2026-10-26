import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class Workspace: ObservableObject {
    @Published var images: [QueueImage] = [] { didSet { observeImages() } }
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isMultiSelecting = false
    @Published private(set) var markedIDs: Set<UUID> = []
    var processingImages: [QueueImage] { isMultiSelecting ? images.filter { markedIDs.contains($0.id) } : selectedImage.map { [$0] } ?? [] }
    @Published var canStartProcessing: @MainActor () -> Bool = { true }
    var canProcessSelection: Bool { !isShuttingDown && canStartProcessing() && !processingImages.isEmpty && !isLoading && !isExporting && pendingRestart == nil && options.isValid }
    var workflow: ProcessingWorkflow?

    func toggleMultiSelection() {
        guard !busy else { return }
        isMultiSelecting.toggle()
        markedIDs = isMultiSelecting ? Set(selectedID.map { [$0] } ?? []) : []
    }
    func toggleMarked(_ image: QueueImage) {
        guard isMultiSelecting, !busy, images.contains(where: { $0.id == image.id }) else { return }
        if !markedIDs.insert(image.id).inserted { markedIDs.remove(image.id) }
    }
    func markAll() { guard isMultiSelecting, !busy else { return }; markedIDs = Set(images.map(\.id)) }
    func clearMarks() { guard !busy else { return }; markedIDs.removeAll() }
    var selectedImage: QueueImage? { images.first { $0.id == selectedID } }
    var input: ImageAsset? { selectedImage?.input }
    var result: ProcessingResult? { selectedImage?.result }
    @Published var options = ProcessingOptions() {
        didSet {
            if persistOptions, let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "processingOptions.v2") }
        }
    }
    private let persistOptions: Bool
    @Published var preview: PreviewMode = .result
    @Published var split = 0.5
    @Published var zoom: CGFloat = 1
    @Published private(set) var viewResetID = UUID()
    @Published var actualSizeRequested = false
    @Published var isProcessing = false
    @Published var isLoading = false
    @Published var isExporting = false
    @Published private var pendingImports: [URL] = []
    @Published var tileProgress: TileProgress?
    @Published var stage = L("正在准备图片")
    @Published var startedAt = Date()
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var activePanels: Set<CanvasPanel> = Set(CanvasPanel.allCases)
    var showsOptions: Bool {
        get { activePanels.contains(.options) }
        set { if newValue { activePanels.insert(.options) } else { activePanels.remove(.options) } }
    }
    var showsImages: Bool {
        get { activePanels.contains(.images) }
        set { if newValue { activePanels.insert(.images) } else { activePanels.remove(.images) } }
    }
    @Published var pixelScale: CGFloat = 1
    var displayedAsset: ImageAsset? { preview == .original ? input : (result?.asset ?? input) }
    @Published private(set) var activeID: UUID?
    @Published private(set) var batchIndex = 0
    @Published private(set) var batchCount = 0
    @Published private(set) var activeOptions: ProcessingOptions?
    @Published var showsRestartConfirmation = false
    @Published private var restartCandidateIDs: [UUID] = []
    private struct ProcessingRequest {
        let imageIDs: [UUID]
        let settings: ProcessingOptions
    }
    @Published private var pendingRestart: ProcessingRequest?
    @Published private var cancellationRequested = false
    @Published private var isShuttingDown = false
    private let makeInference: @MainActor () -> any WorkspaceInference
    nonisolated(unsafe) private var engine: (any WorkspaceInference)?
    nonisolated(unsafe) private var task: Task<Void, Never>?
    @Published private var operationID = UUID()
    private var imageChanges: [AnyCancellable] = []
    private var availabilityChanges: AnyCancellable?
    let directory: URL

    init(persistOptions: Bool = true, workflow: ProcessingWorkflow? = nil,
         makeInference: @escaping @MainActor () -> any WorkspaceInference = { InferenceEngine() }) {
        self.persistOptions = persistOptions
        self.workflow = workflow
        self.makeInference = makeInference
        if persistOptions, let data = UserDefaults.standard.data(forKey: "processingOptions.v2"),
           let saved = try? JSONDecoder().decode(ProcessingOptions.self, from: data) { options = saved }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Waifu2x-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { task?.cancel(); engine?.cancel(); try? FileManager.default.removeItem(at: directory) }

    /// External maintenance affects the processing gate even while the image
    /// queue itself is unchanged. Keep that dependency explicit on macOS 13.
    func observeProcessingAvailability(_ changes: ObservableObjectPublisher) {
        availabilityChanges = changes.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func observeImages() {
        imageChanges = images.map { image in
            image.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
    }

    var busy: Bool { isProcessing || isLoading || isExporting }
    var isSelectedProcessing: Bool { isProcessing && selectedID == activeID }
    var hasChangedOptions: Bool { result.map { $0.options != options } ?? false }
    var completedImages: [QueueImage] { images.filter { $0.result != nil } }
    var pendingImages: [QueueImage] { images.filter { $0.result == nil || $0.result?.options != options } }
    var activeName: String { images.first { $0.id == activeID }?.input.name ?? "" }
    var selectedPosition: Int { (images.firstIndex { $0.id == selectedID } ?? 0) + 1 }

    func select(_ image: QueueImage) {
        guard selectedID != image.id else { return }
        selectedID = image.id
        resetView()
    }

    func remove(_ image: QueueImage) {
        guard !busy, let index = images.firstIndex(where: { $0.id == image.id }) else { return }
        try? FileManager.default.removeItem(at: image.input.url)
        if let result = image.result { try? FileManager.default.removeItem(at: result.asset.url) }
        images.remove(at: index)
        markedIDs.remove(image.id)
        if selectedID == image.id {
            selectedID = images.isEmpty ? nil : images[min(index, images.count - 1)].id
            resetView()
        }
    }

    func chooseImage() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP, .bmp]
        panel.allowsMultipleSelection = true
        panel.message = L("选择一张或多张图片，加入处理列表")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.load(panel.urls) }
        }
    }

    func load(_ url: URL) { load([url]) }
    func load(_ urls: [URL]) {
        guard !isProcessing, !isExporting, !urls.isEmpty else { return }
        pendingImports.append(contentsOf: urls)
        guard !isLoading else { return }
        isLoading = true
        Task {
            var added: [QueueImage] = []
            var failures: [String] = []
            while !pendingImports.isEmpty {
                let url = pendingImports.removeFirst()
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    let directory = directory
                    let asset = try await Task.detached(priority: .userInitiated) { try ImageCodec.load(url, workingDirectory: directory) }.value
                    // Localize display names for our generated inputs while retaining their stable paths.
                    let name: String
                    if url == directory.appendingPathComponent("剪贴板图片.png") { name = L("剪贴板图片.png") }
                    else if url == directory.appendingPathComponent("山与海.png") { name = L("山与海.png") }
                    else { name = asset.name }
                    let image = QueueImage(input: ImageAsset(url: asset.url, image: asset.image, name: name))
                    images.append(image); added.append(image)
                } catch { failures.append(L("%@：%@", url.lastPathComponent, error.localizedDescription)) }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            if let first = added.first { select(first) }
            isLoading = false
            notice = added.count > 1 ? L("已添加 %d 张图片", added.count) : nil
            if !failures.isEmpty { errorMessage = L("%d 张图片未能导入；其余图片已加入列表。\n\n%@", failures.count, failures.prefix(5).joined(separator: "\n")) }
        }
    }

    func pasteImage() { importClipboard(.general) }
    func importClipboard(_ pasteboard: NSPasteboard) {
        guard !busy else { return }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { load(files); return }
        }
        guard let image = NSImage(pasteboard: pasteboard), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = L("剪贴板中没有图片。"); return
        }
        do {
            let url = directory.appendingPathComponent("剪贴板图片.png")
            try ImageCodec.writePNG(cgImage, to: url); load(url)
        } catch { errorMessage = error.localizedDescription }
    }

    func openSample() {
        guard !busy else { return }
        do {
            let url = directory.appendingPathComponent("山与海.png")
            try ImageCodec.writePNG(SampleArtwork.make(), to: url)
            load(url)
        } catch { errorMessage = error.localizedDescription }
    }

    func process() { requestProcessing(processingImages) }
    func processAll() { requestProcessing(images) }
    func processPending() { requestProcessing(pendingImages) }

    private func requestProcessing(_ queue: [QueueImage]) {
        guard !isShuttingDown, canStartProcessing(), !queue.isEmpty, !isLoading, !isExporting, pendingRestart == nil, options.isValid else { return }
        if isProcessing {
            restartCandidateIDs = queue.map(\.id)
            showsRestartConfirmation = true
        } else { beginProcessing(queue) }
    }

    func dismissRestartConfirmation() {
        showsRestartConfirmation = false
        restartCandidateIDs = []
    }

    func confirmRestart() {
        let request = ProcessingRequest(imageIDs: restartCandidateIDs, settings: options)
        dismissRestartConfirmation()
        guard !isShuttingDown, canStartProcessing(), !request.imageIDs.isEmpty, request.settings.isValid else { return }
        if isProcessing {
            // The current task owns cleanup. It starts the replacement only
            // after the inference worker has returned and released its resources.
            cancel()
            pendingRestart = request
            stage = L("正在重新开始增强")
        } else {
            beginProcessing(images.filter { request.imageIDs.contains($0.id) }, settings: request.settings)
        }
    }

    private func beginProcessing(_ queue: [QueueImage], settings requestedSettings: ProcessingOptions? = nil) {
        let settings = requestedSettings ?? options
        guard !isShuttingDown, canStartProcessing(), !queue.isEmpty, !busy, settings.isValid else { return }
        let directory = directory
        let workflow = workflow
        let id = UUID()
        operationID = id
        cancellationRequested = false
        isProcessing = true
        batchCount = queue.count
        batchIndex = 0
        activeOptions = settings
        notice = nil
        for image in queue { image.state = .waiting; image.failure = nil }
        task = Task {
            var succeeded = 0
            var failed = 0
            for (index, image) in queue.enumerated() {
                if cancellationRequested || Task.isCancelled { break }
                // Follow the active image unless the user has chosen another preview.
                if activeID == nil || selectedID == activeID { select(image) }
                activeID = image.id
                batchIndex = index + 1
                tileProgress = nil
                stage = L("正在载入模型")
                startedAt = Date()
                image.state = .processing
                let engine = makeInference()
                self.engine = engine
                let lease = workflow?.beginInference()
                defer { if let lease { workflow?.endInference(lease) } }
                do {
                    let input = image.input
                    let url = try await Task.detached(priority: .userInitiated) {
                        defer { lease?.finish() }
                        return try engine.run(input: input, options: settings, directory: directory, progress: { progress in
                            Task { @MainActor in
                                if self.operationID == id && self.activeID == image.id && image.state == .processing && !self.cancellationRequested { self.tileProgress = progress }
                            }
                        }) { stage in
                            Task { @MainActor in
                                if self.operationID == id && self.activeID == image.id && image.state == .processing && !self.cancellationRequested { self.stage = stage }
                            }
                        }
                    }.value
                    guard operationID == id else { try? FileManager.default.removeItem(at: url); return }
                    if cancellationRequested { try? FileManager.default.removeItem(at: url); throw CancellationError() }
                    let output = try await Task.detached { try ImageCodec.readPNG(url) }.value
                    guard operationID == id, !cancellationRequested else {
                        try? FileManager.default.removeItem(at: url)
                        throw CancellationError()
                    }
                    if let previous = image.result { try? FileManager.default.removeItem(at: previous.asset.url) }
                    image.result = ProcessingResult(asset: ImageAsset(url: url, image: output, name: input.name), options: settings, duration: Date().timeIntervalSince(startedAt))
                    image.state = .completed
                    succeeded += 1
                    if selectedID == image.id { preview = .result; resetView() }
                } catch is CancellationError {
                    image.state = .cancelled
                    cancellationRequested = true
                } catch {
                    image.state = .failed
                    image.failure = error.localizedDescription
                    failed += 1
                    if queue.count == 1 { errorMessage = error.localizedDescription }
                }
                self.engine = nil
            }
            for image in queue where image.state == .waiting { image.state = .ready }
            if operationID == id {
                workflow?.completeBatch(id: id, count: queue.count, succeeded: succeeded, failed: failed,
                                        cancelled: cancellationRequested || Task.isCancelled || pendingRestart != nil || isShuttingDown)
                if cancellationRequested { notice = queue.count == 1 ? L("已取消处理") : L("已停止批量处理 · 保留已完成的 %d 张结果", succeeded) }
                else if queue.count > 1 { notice = failed > 0 ? L("批量完成 · %d 张成功，%d 张失败，请在图片列表查看", succeeded, failed) : L("批量完成 · %d 张成功", succeeded) }
                isProcessing = false; tileProgress = nil; activeID = nil; activeOptions = nil; task = nil
                if let request = pendingRestart {
                    pendingRestart = nil
                    beginProcessing(images.filter { request.imageIDs.contains($0.id) }, settings: request.settings)
                }
                if isShuttingDown { try? FileManager.default.removeItem(at: directory) }
            }
        }
    }

    func shutdown() {
        isShuttingDown = true
        workflow?.shutdown()
        pendingRestart = nil
        dismissRestartConfirmation()
        cancellationRequested = true
        engine?.cancel(); task?.cancel()
        if !isProcessing { try? FileManager.default.removeItem(at: directory) }
    }
    func prepareForTermination() async {
        let runningTask = task
        shutdown()
        await runningTask?.value
        try? FileManager.default.removeItem(at: directory)
    }
    func cancel() {
        pendingRestart = nil
        guard isProcessing else { return }
        cancellationRequested = true; stage = L("正在取消"); engine?.cancel()
    }
    func dismissPanelOrCancel() {
        if !activePanels.isEmpty { activePanels.removeAll() } else { cancel() }
    }
    func resetView() { zoom = 1; actualSizeRequested = false; viewResetID = UUID() }

}
