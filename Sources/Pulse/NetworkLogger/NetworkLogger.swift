// The MIT License (MIT)
//
// Copyright (c) 2020–2022 Alexander Grebenyuk (github.com/kean).

import Foundation

/// A wrapper on top of ``LoggerStore`` that simplifies logging of network requests.
///
/// - note: ``NetworkLogger`` is used internally by ``URLSessionProxyDelegate`` and
/// should generally not be used directly.
public final class NetworkLogger: @unchecked Sendable {
    private let configuration: Configuration
    private let store: LoggerStore

    private let includedHosts: [Regex]
    private let includedURLs: [Regex]
    private let excludedHosts: [Regex]
    private let excludedURLs: [Regex]

    private let lock = NSLock()

    /// The logger configuration.
    public struct Configuration: Sendable {
        /// If enabled, the requests are not marked as completed until the decoding
        /// is done (see ``NetworkLogger/logTask(_:didFinishDecodingWithError:)``.
        /// If the request itself fails, the task completes immediately.
        public var isWaitingForDecoding: Bool

        /// Stores logs only for the included hosts.
        ///
        /// - note: Supports wildcards, e.g. `*.example.com`, and full regex
        /// when ``isRegexEnabled`` option is enabled.
        public var includedHosts: Set<String> = []

        /// Stores logs only for the included URLs.
        ///
        /// - note: Supports wildcards, e.g. `*.example.com`, and full regex
        /// when ``isRegexEnabled`` option is enabled.
        public var includedURLs: Set<String> = []

        /// Excludes the given hosts from the logs.
        ///
        /// - note: Supports wildcards, e.g. `*.example.com`, and full regex
        /// when ``isRegexEnabled`` option is enabled.
        public var excludedHosts: Set<String> = []

        /// Excludes the given URLs from the logs.
        ///
        /// - note: Supports wildcards, e.g. `*.example.com`, and full regex
        /// when ``isRegexEnabled`` option is enabled.
        public var excludedURLs: Set<String> = []

        /// If enabled, processes `include` and `exclude` patterns using regex.
        /// By default, patterns support only basic wildcard syntax: `*.example.com`.
        public var isRegexEnabled = false

        /// Gets called when the logger receives an event. You can use it to
        /// modify the event before it is stored in order, for example, filter
        /// out some sensitive information. If you return `nil`, the event
        /// is ignored completely.
        public var willHandleEvent: @Sendable (LoggerStore.Event) -> LoggerStore.Event? = { $0 }

        /// Initializes the configuration.
        public init(isWaitingForDecoding: Bool = false) {
            self.isWaitingForDecoding = isWaitingForDecoding
        }
    }

    /// Initialiers the network logger.
    ///
    /// - parameters:
    ///   - store: The target store for network requests.
    ///   - configuration: The store configuration.
    public init(store: LoggerStore = .shared, configuration: Configuration = .init()) {
        self.store = store
        self.configuration = configuration

        func process(_ pattern: String) -> Regex? {
            do {
                let pattern = configuration.isRegexEnabled ? pattern : pattern
                    .replacingOccurrences(of: ".", with: "\\.")
                    .replacingOccurrences(of: "*", with: ".*?")
                return try Regex(pattern)
            } catch {
                debugPrint("Failed to parse pattern: \(pattern) \(error)")
                return nil
            }
        }

        self.includedHosts = configuration.includedHosts.compactMap(process)
        self.includedURLs = configuration.includedURLs.compactMap(process)
        self.excludedHosts = configuration.excludedHosts.compactMap(process)
        self.excludedURLs = configuration.excludedURLs.compactMap(process)
    }

    /// Initialiers and configures the network logger.
    public convenience init(store: LoggerStore = .shared, _ configure: (inout Configuration) -> Void) {
        var configuration = Configuration()
        configure(&configuration)
        self.init(store: store, configuration: configuration)
    }

    // MARK: Logging

    /// Logs the task creation (optional).
    public func logTaskCreated(_ task: URLSessionTask) {
        lock.lock()
        let context = context(for: task)
        lock.unlock()

        guard let originalRequest = task.originalRequest ?? context.request else { return }
        send(.networkTaskCreated(LoggerStore.Event.NetworkTaskCreated(
            taskId: context.taskId,
            taskType: NetworkLogger.TaskType(task: task),
            createdAt: Date(),
            originalRequest: .init(originalRequest),
            currentRequest: task.currentRequest.map(Request.init),
            session: LoggerStore.Session.current.id
        )))
    }

    /// Logs the task data that gets appended to the previously received chunks (required).
    public func logDataTask(_ dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let context = self.context(for: dataTask)
        context.data.append(data)
        lock.unlock()
    }

    public func logTask(_ task: URLSessionTask, didUpdateProgress progress: (completed: Int64, total: Int64)) {
        lock.lock()
        let context = self.context(for: task)
        lock.unlock()

        send(.networkTaskProgressUpdated(.init(
            taskId: context.taskId,
            url: task.originalRequest?.url,
            completedUnitCount: progress.completed,
            totalUnitCount: progress.total
        )))
    }

    /// Logs the task completion (required).
    public func logTask(_ task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil || !configuration.isWaitingForDecoding else { return }
        _logTask(task, didCompleteWithError: error)
    }

    /// Logs the task metrics (optional).
    public func logTask(_ task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        context(for: task).metrics = NetworkLogger.Metrics(metrics: metrics)
        lock.unlock()
    }

    /// Logs the task metrics (optional).
    public func logTask(_ task: URLSessionTask, didFinishCollecting metrics: NetworkLogger.Metrics) {
        lock.lock()
        context(for: task).metrics = metrics
        lock.unlock()
    }

    public func logTask(_ task: URLSessionTask, didFinishDecodingWithError error: Error?) {
        _logTask(task, didCompleteWithError: error)
    }

    private func _logTask(_ task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let context = self.context(for: task)
        tasks[TaskKey(task: task)] = nil

        guard let originalRequest = task.originalRequest ?? context.request else {
            lock.unlock()
            return // This should never happen
        }

        let metrics = context.metrics
        let data = context.data
        lock.unlock()

        send(.networkTaskCompleted(.init(
            taskId: context.taskId,
            taskType: NetworkLogger.TaskType(task: task),
            createdAt: Date(),
            originalRequest: Request(originalRequest),
            currentRequest: task.currentRequest.map(Request.init),
            response: task.response.map(Response.init),
            error: error.map(ResponseError.init),
            requestBody: originalRequest.httpBody ?? originalRequest.httpBodyStreamData(),
            responseBody: data,
            metrics: metrics,
            session: LoggerStore.Session.current.id
        )))
    }

    private func send(_ event: LoggerStore.Event) {
        guard filter(event) else {
            return
        }
        guard let event = configuration.willHandleEvent(event) else {
            return
        }
        store.handle(event)
    }

    private func filter(_ event: LoggerStore.Event) -> Bool {
        guard let url = event.url else {
            return false // Should never happen
        }
        var host = url.host ?? ""
        if url.scheme == nil, let url = URL(string: "https://" + url.absoluteString) {
            host = url.host ?? "" // URL(string: "example.com")?.host with not scheme returns host: ""
        }
        let absoluteString = url.absoluteString
        if !includedHosts.isEmpty || !includedURLs.isEmpty {
            guard includedHosts.contains(where: { $0.isMatch(host) }) ||
                    includedURLs.contains(where: { $0.isMatch(absoluteString) }) else {
                return false
            }
        }
        if !excludedHosts.isEmpty && excludedHosts.contains(where: { $0.isMatch(host) }) {
            return false
        }
        if !excludedURLs.isEmpty && excludedURLs.contains(where: { $0.isMatch(absoluteString) }) {
            return false
        }
        return true
    }

    // MARK: - Private

    private var tasks: [TaskKey: TaskContext] = [:]

    final class TaskContext {
        let taskId = UUID()
        var request: URLRequest?
        lazy var data = Data()
        var metrics: NetworkLogger.Metrics?
    }

    private func context(for task: URLSessionTask) -> TaskContext {
        func getContext() -> TaskContext {
            let key = TaskKey(task: task)
            if let context = tasks[key] {
                return context
            }
            let context = TaskContext()
            tasks[key] = context
            return context
        }
        let context = getContext()
        if let request = task.originalRequest {
            context.request = request
        }
        return context
    }

    private struct TaskKey: Hashable {
        weak var task: URLSessionTask?

        var id: ObjectIdentifier? { task.map(ObjectIdentifier.init) }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id?.hashValue)
        }

        static func == (lhs: TaskKey, rhs: TaskKey) -> Bool {
            lhs.task != nil && lhs.id == rhs.id
        }
    }
}

private extension URLSessionTask {
    var url: String? {
        originalRequest?.url?.absoluteString
    }
}