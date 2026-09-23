import Foundation

private final class ResponseFileCollector: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let maximumBytes: Int
    private let destination: URL
    private var session: URLSession?
    private var handle: FileHandle?
    private var response: URLResponse?
    private var receivedBytes = 0
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private let lock = NSLock()

    init(maximumBytes: Int, destination: URL) {
        self.maximumBytes = maximumBytes
        self.destination = destination
    }

    func upload(request: URLRequest, file: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await run(configuration: configuration) { session in
            session.uploadTask(with: request, fromFile: file)
        }
    }

    func download(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await run(configuration: configuration) { session in
            session.dataTask(with: request)
        }
    }

    private func run(configuration: URLSessionConfiguration, task: @escaping (URLSession) -> URLSessionTask) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                lock.lock()
                self.session = session
                lock.unlock()
                task(session).resume()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(PhotoError.message("The server response exceeds the 18 MiB safety limit.")))
            return
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]),
              let handle = try? FileHandle(forWritingTo: destination) else {
            completionHandler(.cancel)
            finish(.failure(PhotoError.message("Cannot create the protected response file.")))
            return
        }
        self.response = response
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard receivedBytes <= maximumBytes - data.count else {
            dataTask.cancel()
            finish(.failure(PhotoError.message("The server response exceeds the 18 MiB safety limit.")))
            return
        }
        do {
            try handle?.write(contentsOf: data)
            receivedBytes += data.count
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((destination, response)))
        } else {
            finish(.failure(PhotoError.message("Invalid server response.")))
        }
    }

    private func cancel() {
        lock.lock()
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        try? handle?.close()
        handle = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

struct GeminiClient {
    static let maximumResponseBytes = 18 * 1024 * 1024
    static let maximumResultBytes = 12 * 1024 * 1024

    let configuration: ServerConfiguration
    let session: URLSession

    init(configuration: ServerConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 360
        sessionConfiguration.timeoutIntervalForResource = 360
        sessionConfiguration.urlCache = nil
        self.session = session ?? URLSession(configuration: sessionConfiguration)
    }

    func availableModels() async throws -> [String] {
        let request = authenticatedRequest(path: "openai/v1/models")
        let responseFile = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoServer-models-\(UUID().uuidString).json")
        let collector = ResponseFileCollector(maximumBytes: Self.maximumResponseBytes, destination: responseFile)
        let (file, response) = try await collector.download(request: request, configuration: session.configuration)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try Self.check(response, data: data)
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model]? }
        let models = try JSONDecoder().decode(Models.self, from: data).data ?? []
        guard !models.isEmpty else { throw PhotoError.message("The Gemini session has not published any available models. Check the server session.") }
        return models
    }

    func checkConnection(model: String? = nil) async throws -> String {
        let models = try await availableModels()
        let selected = model ?? Settings.model
        guard models.contains(selected) else {
            guard let fallback = Settings.preferredModel(from: models) else { throw PhotoError.message("The Gemini session has not published any available models.") }
            return "Connected · \(fallback)"
        }
        return "Connected · \(selected)"
    }

    struct AuthStatus: Decodable {
        let status: String
        let message: String?
    }

    private struct LoginSession: Decodable {
        let status: String
        let url: URL?
    }

    func authStatus(check: Bool = false) async throws -> AuthStatus {
        let path = check ? "api/gemini/auth/check" : "api/gemini/auth/status"
        var request = authenticatedRequest(path: path)
        if check { request.httpMethod = "POST" }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 4096 else { throw PhotoError.message("Invalid Gemini auth status response.") }
        try Self.check(response, data: data)
        return try JSONDecoder().decode(AuthStatus.self, from: data)
    }

    func createLoginSession() async throws -> URL? {
        var request = authenticatedRequest(path: "api/gemini/auth/login-session")
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        guard data.count <= 4096 else { throw PhotoError.message("Invalid Gemini login response.") }
        try Self.check(response, data: data)
        let login = try JSONDecoder().decode(LoginSession.self, from: data)
        guard let url = login.url else { return nil }
        guard url.scheme == "https", url.host == configuration.baseURL.host,
              url.path.hasPrefix("/gemini-login/start/") else {
            throw PhotoError.message("The server returned an invalid Gemini login link.")
        }
        return url
    }

    // Build a JSON upload file incrementally: no full-resolution UIImage, no giant JSON String.
    static func makeRequestFile(image: URL, orientation: Int32, model: String, directory: URL) throws -> URL {
        let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= ImageFiles.maxInputBytes else { throw PhotoError.message("The source must be at most 25 MiB. No image was resized.") }
        guard (1...8).contains(orientation) else { throw PhotoError.message("The source image has an invalid orientation.") }
        let mime = try ImageFiles.mime(image)
        let url = directory.appendingPathComponent("request.json")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw PhotoError.message("Cannot create the protected upload file.")
        }
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        let reader = try FileHandle(forReadingFrom: image)
        defer { try? reader.close() }
        let fields: [String: Any] = ["model": model, "prompt": Settings.prompt, "n": 1, "response_format": "b64_json", "input_orientation": orientation]
        var prefix = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        prefix.removeLast()
        prefix.append(Data(",\"image\":\"data:\(mime);base64,".utf8))
        try writer.write(contentsOf: prefix)
        // Multiple of 3: concatenated blocks remain valid base64.
        while let chunk = try reader.read(upToCount: 3 * 16384), !chunk.isEmpty {
            try Task.checkCancellation()
            try writer.write(contentsOf: chunk.base64EncodedData())
        }
        try writer.write(contentsOf: Data("\"}".utf8))
        return url
    }

    func process(requestFile: URL, directory: URL) async throws -> URL {
        var request = authenticatedRequest(path: "openai/v1/images/generations")
        request.httpMethod = "POST"
        request.timeoutInterval = 360
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let responseFile = directory.appendingPathComponent("response.json")
        let collector = ResponseFileCollector(maximumBytes: Self.maximumResponseBytes, destination: responseFile)
        var sessionConfiguration = session.configuration
        sessionConfiguration.timeoutIntervalForRequest = 360
        sessionConfiguration.timeoutIntervalForResource = 360
        sessionConfiguration.urlCache = nil
        let (file, response) = try await collector.upload(request: request, file: requestFile, configuration: sessionConfiguration)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        try Task.checkCancellation()
        try Self.check(response, data: data)
        return try Self.decodeResult(data, directory: directory)
    }

    private func authenticatedRequest(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-PhotoServer-Key")
        return request
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PhotoError.message("Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else {
            struct APIError: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
            let detail = (try? JSONDecoder().decode(APIError.self, from: data).error.message) ?? "Request failed."
            throw PhotoError.message("HTTP \(http.statusCode): \(detail.prefix(400))")
        }
    }

    static func decodeResult(_ data: Data, directory: URL) throws -> URL {
        guard data.count <= maximumResponseBytes else { throw PhotoError.message("The server response exceeds the 18 MiB safety limit.") }
        struct Response: Decodable { struct Item: Decodable { let b64_json: String? }; let data: [Item] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let maximumEncodedLength = ((maximumResultBytes + 2) / 3) * 4
        guard let encoded = response.data.first?.b64_json, encoded.utf8.count <= maximumEncodedLength,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumResultBytes else {
            throw PhotoError.message("The server returned no usable image within the 12 MiB safety limit.")
        }
        let url = directory.appendingPathComponent("result.image")
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        guard ["image/jpeg", "image/png"].contains(try ImageFiles.mime(url)) else { throw PhotoError.message("Expected PNG or JPEG result.") }
        return url
    }
}
