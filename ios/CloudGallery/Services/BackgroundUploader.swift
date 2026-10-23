import Foundation
import CloudGalleryCore

/// Describes one upload task; stored in `URLSessionTask.taskDescription` so it survives app relaunches.
struct UploadJob: Codable, Equatable {
    var itemId: String
    var role: UploadRole
    /// Multipart body file name inside the staging directory.
    var bodyFile: String
    var contentType: String
    var attempt: Int
}

/// Owns the background `URLSession`s that upload media to Telegram while the app is suspended.
/// Two sessions exist so the Wi-Fi-only preference can be enforced by the system.
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let wifiIdentifier = "com.shahil-kv.cloudgallery.upload.wifi"
    static let anyNetworkIdentifier = "com.shahil-kv.cloudgallery.upload.any"

    private unowned let env: AppEnvironment
    private let lock = NSLock()
    private var responseData: [String: Data] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private var _wifiSession: URLSession?
    private var _anySession: URLSession?

    /// Called on any thread when a job finishes (success or failure).
    var onJobFinished: ((UploadJob, Result<TGMessage, Error>) -> Void)?
    /// Called when a background session has delivered all pending events.
    var onAllEventsDelivered: (() -> Void)?

    init(environment: AppEnvironment) {
        self.env = environment
        super.init()
    }

    private func makeSession(_ identifier: String) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 24
        let wifiOnly = identifier == Self.wifiIdentifier
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func session(wifiOnly: Bool) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if wifiOnly {
            if _wifiSession == nil { _wifiSession = makeSession(Self.wifiIdentifier) }
            return _wifiSession!
        }
        if _anySession == nil { _anySession = makeSession(Self.anyNetworkIdentifier) }
        return _anySession!
    }

    /// Recreates both sessions so tasks from a previous launch report back to this delegate.
    func activate() {
        _ = session(wifiOnly: true)
        _ = session(wifiOnly: false)
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func attach(identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        completionHandlers[identifier] = completion
        lock.unlock()
        _ = session(wifiOnly: identifier == Self.wifiIdentifier)
    }

    func bodyURL(_ job: UploadJob) -> URL { env.stagingDirectory.appendingPathComponent(job.bodyFile) }

    func enqueue(_ job: UploadJob, delay: TimeInterval) throws {
        guard let token = env.token else { throw TelegramError.api(code: 401, description: "Not configured") }
        let client = TelegramClient(token: token)
        var request = URLRequest(url: client.methodURL("sendDocument"))
        request.httpMethod = "POST"
        request.setValue(job.contentType, forHTTPHeaderField: "Content-Type")
        let task = session(wifiOnly: Prefs.wifiOnly).uploadTask(with: request, fromFile: bodyURL(job))
        task.taskDescription = String(data: try JSONEncoder().encode(job), encoding: .utf8)
        if delay > 0.05 { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        task.countOfBytesClientExpectsToSend = (try? FileManager.default.attributesOfItem(atPath: bodyURL(job).path)[.size] as? NSNumber)?.int64Value ?? NSURLSessionTransferSizeUnknown
        task.countOfBytesClientExpectsToReceive = 2048
        task.resume()
    }

    func allTasks() async -> [URLSessionTask] {
        let a = await session(wifiOnly: true).allTasks
        let b = await session(wifiOnly: false).allTasks
        return (a + b).filter { $0.state != .completed && $0.state != .canceling }
    }

    func inFlightJobs() async -> [UploadJob] {
        await allTasks().compactMap { task in
            task.taskDescription.flatMap { try? JSONDecoder().decode(UploadJob.self, from: Data($0.utf8)) }
        }
    }

    func cancelAll() {
        session(wifiOnly: true).getAllTasks { $0.forEach { $0.cancel() } }
        session(wifiOnly: false).getAllTasks { $0.forEach { $0.cancel() } }
    }

    // MARK: - URLSessionDataDelegate

    private func key(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session.configuration.identifier ?? "")#\(task.taskIdentifier)"
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseData[key(session, dataTask), default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = responseData.removeValue(forKey: key(session, task)) ?? Data()
        lock.unlock()
        guard let desc = task.taskDescription,
              let job = try? JSONDecoder().decode(UploadJob.self, from: Data(desc.utf8)) else { return }

        let result: Result<TGMessage, Error>
        if let error {
            if (error as? URLError)?.code == .cancelled { result = .failure(CancellationError()) }
            else { result = .failure(TelegramError.network(error.localizedDescription)) }
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            result = Result { try TelegramResponseParser.parse(TGMessage.self, data: data, statusCode: status) }
        }
        onJobFinished?(job, result)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let id = session.configuration.identifier else { return }
        lock.lock()
        let handler = completionHandlers.removeValue(forKey: id)
        lock.unlock()
        onAllEventsDelivered?()
        if let handler { DispatchQueue.main.async(execute: handler) }
    }
}
