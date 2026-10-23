import Foundation

protocol ModelFileTransferring: AnyObject, Sendable {
    var resumeData: Data? { get }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
    func pause() async -> Data?
    func cancel()
}

typealias ModelDownloadTransportFactory = @Sendable (URL, Int64) -> any ModelFileTransferring

/// URLSession owns partial bytes and supplies its genuine resume data when paused.
final class ModelFileDownload: NSObject, ModelFileTransferring, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedBytes: Int64
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var callback: (@Sendable (Int64, Int64?) -> Void)?
    private var result: Result<URL, Error>?
    private var hasStarted = false
    private var savedResumeData: Data?
    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return savedResumeData }

    init(destination: URL, expectedBytes: Int64, configuration: URLSessionConfiguration = .default) {
        self.destination = destination; self.expectedBytes = expectedBytes
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }

    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !self.hasStarted else {
                    lock.unlock(); continuation.resume(throwing: URLError(.cannotLoadFromNetwork)); return
                }
                self.hasStarted = true
                self.continuation = continuation; callback = progress
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func pause() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock(); let task = task; let previous = savedResumeData; lock.unlock()
            guard let task else { continuation.resume(returning: previous); return }
            task.cancel(byProducingResumeData: { [weak self] data in
                if let self { self.lock.lock(); self.savedResumeData = data; self.lock.unlock() }
                continuation.resume(returning: data)
            })
        }
    }

    func cancel() { lock.lock(); let active = task; lock.unlock(); active?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let callback = callback
        if totalBytesWritten > expectedBytes {
            result = .failure(ModelDownloadFailure.message(L("模型文件大小与清单不符，请重试")))
        }
        lock.unlock()
        if totalBytesWritten > expectedBytes { downloadTask.cancel(); return }
        callback?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(fileOffset, expectedTotalBytes > 0 ? expectedTotalBytes : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let previous = result; lock.unlock()
        if case .failure? = previous { return }
        let response = downloadTask.response as? HTTPURLResponse
        do {
            guard let response, (200...299).contains(response.statusCode) else {
                throw ModelDownloadFailure.message(L("模型下载失败，服务器状态码 %d", response?.statusCode ?? -1))
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(size ?? -1) == expectedBytes else {
                throw ModelDownloadFailure.message(L("模型文件大小与清单不符，请重试"))
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); result = .success(destination); lock.unlock()
        } catch { lock.lock(); result = .failure(error); lock.unlock() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { savedResumeData = data }
        let completion = continuation; continuation = nil
        let value = result ?? .failure(error ?? URLError(.unknown))
        self.task = nil; self.callback = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        completion?.resume(with: value)
    }
}
