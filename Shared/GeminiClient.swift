import Foundation

struct GeminiClient {
    let baseURL: URL
    let session: URLSession
    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 360
        config.timeoutIntervalForResource = 360
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    func checkConnection() async throws -> String {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("openai/v1/models"))
        try Self.check(response, data: data)
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model]? }
        let models = try JSONDecoder().decode(Models.self, from: data).data ?? []
        guard models.contains(where: { $0.id == Settings.model }) else { throw PhotoError.message("The Gemini session has not published \(Settings.model). Check the server session.") }
        return "Connected · \(Settings.model)"
    }

    // Build a JSON upload file incrementally: no full-resolution UIImage, no giant JSON String.
    static func makeRequestFile(image: URL, directory: URL) throws -> URL {
        let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= ImageFiles.maxInputBytes else { throw PhotoError.message("The source must be at most 25 MiB. No image was resized.") }
        let mime = try ImageFiles.mime(image)
        let url = directory.appendingPathComponent("request.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        let reader = try FileHandle(forReadingFrom: image)
        defer { try? reader.close() }
        let fields: [String: Any] = ["model": Settings.model, "prompt": Settings.prompt, "n": 1, "response_format": "b64_json"]
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
        var request = URLRequest(url: baseURL.appendingPathComponent("openai/v1/images/generations"))
        request.httpMethod = "POST"
        request.timeoutInterval = 360
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: requestFile)
        try Task.checkCancellation()
        try Self.check(response, data: data)
        return try Self.decodeResult(data, directory: directory)
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
        struct Response: Decodable { struct Item: Decodable { let b64_json: String? }; let data: [Item] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let encoded = response.data.first?.b64_json, encoded.count <= 48 * 1024 * 1024,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { throw PhotoError.message("The server returned no usable image.") }
        let url = directory.appendingPathComponent("result.image")
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        guard ["image/jpeg", "image/png"].contains(try ImageFiles.mime(url)) else { throw PhotoError.message("Expected PNG or JPEG result.") }
        return url
    }
}
